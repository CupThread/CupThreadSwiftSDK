import Foundation

/// Persists a stable anonymous user token across app launches.
/// Used to track vote state and own pending requests without requiring authentication.
///
/// The token is a plain UUID securely stored in the system Keychain
/// (`kSecClassGenericPassword` in the data-protection keychain, so the
/// device-only accessibility guarantee holds on macOS as well — SEC-33).
/// It never carries personal data and is scoped to this device. On first access, any legacy token
/// stored in `UserDefaults` is automatically migrated to the Keychain and deleted from defaults,
/// preventing plaintext credentials from appearing in device backups.
///
/// ### Behavioral Notes
/// - **Persistence across uninstalls**: On iOS, visionOS, and tvOS, Keychain items survive app
///   uninstallation and reinstallation. The anonymous identity remains stable even if the user
///   deletes and reinstalls the app.
/// - **Resetting settings**: Wiping app settings or resetting defaults does not clear the Keychain item.
///   Call ``reset()`` to clear the identity explicitly.
///
/// ### Token spelling
/// Minted tokens are lowercase UUID strings. The server verifies a signed
/// user-attribute report over the token exactly as presented and only folds
/// it to lowercase afterwards, for identity storage (issue #511); minting the
/// canonical spelling keeps the signed value, the `X-User-Token` header, and
/// the stored profile key byte-identical. Tokens already persisted keep their
/// original spelling and identity — only newly minted ones are canonicalized.
/// Any code that signs with the token must sign exactly the value it sends,
/// never an independently lowercased copy.
///
/// ### One identity per app
///
/// The anonymous identity is scoped per CupThread app key, so a host embedding
/// two CupThread apps keeps two independent end-user identities — votes,
/// comments, and submissions never bleed across apps. Create one store per
/// app key and pass its token wherever the SDK asks for a `userToken`:
///
/// ```swift
/// let store = UserTokenStore(appKey: "app_xxx")
/// FeatureRequestsView(client: client, userToken: store.token)
/// ```
///
/// ``UserTokenStore/shared`` remains the single unscoped store for hosts that
/// embed exactly one CupThread app; a scoped store adopts that legacy
/// identity on its first read so existing users keep their history.
public final class UserTokenStore: @unchecked Sendable {
    /// The shared store, backed by the system Keychain with legacy `UserDefaults` migration.
    ///
    /// This store holds the single legacy (unscoped) identity. Hosts embedding
    /// more than one CupThread app should create one
    /// ``UserTokenStore/init(appKey:)`` per app instead, so each app gets its
    /// own end-user identity.
    public static let shared = UserTokenStore()

    /// The default key used in storage to identify the anonymous token.
    static let defaultKey = "com.cupthread.featureRequestUserToken"

    /// Mints a fresh identity token in the canonical lowercase UUID form.
    ///
    /// `UUID().uuidString` renders hex digits in uppercase. The server folds
    /// the token to lowercase only after HMAC verification, so minting the
    /// folded spelling keeps canonical strings and headers byte-identical
    /// under either normalization order (issue #511).
    private static func mintToken() -> String {
        UUID().uuidString.lowercased()
    }

    private static let processLock = NSLock()

    /// Process-wide memo of the last ephemeral token served for each backing
    /// store while that store was unreadable or could not confirm a write
    /// (issue #567).
    private static let ephemeralMemo = EphemeralTokenMemo()

    /// Process-wide, thread-safe memo of the last ephemeral token served per
    /// backing store (issue #567). Without the memo, every read during such a
    /// window mints a different UUID, so one logical operation that resolves
    /// the identity more than once — an upload session and the submission
    /// finalizing it — would present two different end-user identities to the
    /// server.
    ///
    /// Keyed by the backing store's identity (service + account for
    /// Keychain-backed stores, object identity otherwise), so ``shared`` and
    /// every scoped store each stay self-consistent for the process lifetime
    /// without ever sharing an identity across app keys. Entries are dropped
    /// when a read resolves a stored identity, when a write is confirmed
    /// durable, and when ``reset()`` confirms an erasure — a durable or
    /// stored identity must never be shadowed by a stale memo.
    private final class EphemeralTokenMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var tokens: [String: String] = [:]

        /// The memoized token for `key`, minting and recording a fresh one
        /// when the memo holds none for this backing store yet.
        func serve(forKey key: String) -> String {
            lock.lock()
            defer { lock.unlock() }
            if let memoized = tokens[key] {
                return memoized
            }
            let fresh = mintToken()
            tokens[key] = fresh
            return fresh
        }

        /// Forgets the ephemeral token for `key`.
        func drop(forKey key: String) {
            lock.lock()
            defer { lock.unlock() }
            tokens.removeValue(forKey: key)
        }
    }

    /// The memo key for a backing store: service + account for Keychain
    /// storage (stable across store instances, so ad-hoc
    /// ``init(appKey:)``/``shared`` instances share one run), and object
    /// identity for any other storage.
    private static func ephemeralMemoKey(for storage: any TokenStorage) -> String {
        if let keychain = storage as? KeychainTokenStorage {
            return "keychain|\(keychain.service)|\(keychain.account)"
        }
        return "instance|\(ObjectIdentifier(storage))"
    }

    private let storage: any TokenStorage
    private let legacyUserDefaults: UserDefaults?
    private let legacyKey: String?
    /// Copy-only inheritance source holding the legacy global identity
    /// (the pre-scoping Keychain item). Scoped stores adopt its value on
    /// their first read but never delete it, so sibling app keys and
    /// ``UserTokenStore/shared`` keep access.
    private let legacyGlobalStore: (any TokenStorage)?
    /// Flags that this store verifiably holds a persisted identity — either a
    /// confirmed legacy adoption or a confirmed fresh mint — so ``reset()``
    /// is not undone by re-inheriting the (possibly rotated) global identity.
    /// Never committed on an unconfirmed write.
    private let adoptionDefaults: UserDefaults?
    private let adoptionFlagKey: String?
    /// Only the store that owns the global identity (`.shared`) deletes the
    /// legacy plaintext; scoped stores copy so sibling app keys can inherit.
    private let ownsLegacyPlaintext: Bool
    /// Key under which this store memoizes its ephemeral fallback token in
    /// the process-wide ``ephemeralTokens`` table (issue #567).
    private let ephemeralMemoKey: String

    /// Initializes a token store backed by a custom storage and optional migration source.
    /// Internal to allow unit tests to pass storage doubles and test migration.
    init(
        storage: any TokenStorage,
        legacyUserDefaults: UserDefaults? = nil,
        legacyKey: String? = nil,
        legacyGlobalStore: (any TokenStorage)? = nil,
        adoptionDefaults: UserDefaults? = nil,
        adoptionFlagKey: String? = nil
    ) {
        self.storage = storage
        self.legacyUserDefaults = legacyUserDefaults
        self.legacyKey = legacyKey
        self.legacyGlobalStore = legacyGlobalStore
        self.adoptionDefaults = adoptionDefaults
        self.adoptionFlagKey = adoptionFlagKey
        self.ownsLegacyPlaintext = adoptionFlagKey == nil
        self.ephemeralMemoKey = Self.ephemeralMemoKey(for: storage)
    }

    /// Initializes a production token store backed by Keychain, with automatic migration
    /// from any legacy `UserDefaults` entry.
    public convenience init() {
        self.init(
            storage: KeychainTokenStorage(
                service: KeychainTokenStorage.defaultService,
                account: UserTokenStore.defaultKey
            ),
            legacyUserDefaults: .standard,
            legacyKey: UserTokenStore.defaultKey
        )
    }

    /// Initializes a store whose identity is scoped to one CupThread app key.
    ///
    /// Hosts embedding several CupThread apps must create one store per app
    /// key so votes, comments, and submissions land on separate end-user
    /// profiles. On first read the store adopts the legacy global identity
    /// (from ``UserTokenStore/shared``) if one exists, so users upgrading
    /// from a single-app integration keep their history; afterwards the
    /// identity is fully independent and ``reset()`` never falls back to it.
    ///
    /// - Parameter appKey: The CupThread app key to scope the identity to.
    public convenience init(appKey: String) {
        let scopedKey = UserTokenStore.scopedKey(for: appKey)
        self.init(
            storage: KeychainTokenStorage(
                service: KeychainTokenStorage.defaultService,
                account: scopedKey
            ),
            legacyUserDefaults: .standard,
            legacyKey: UserTokenStore.defaultKey,
            legacyGlobalStore: KeychainTokenStorage(
                service: KeychainTokenStorage.defaultService,
                account: UserTokenStore.defaultKey
            ),
            adoptionDefaults: .standard,
            adoptionFlagKey: UserTokenStore.legacyAdoptionFlagKey(for: appKey)
        )
    }

    /// Initializes a token store backed directly by `UserDefaults`.
    /// Internal to allow unit tests to pass isolated `UserDefaults` and keys.
    init(userDefaults: UserDefaults = .standard, key: String = UserTokenStore.defaultKey) {
        let storage = UserDefaultsTokenStorage(userDefaults: userDefaults, key: key)
        self.storage = storage
        self.legacyUserDefaults = nil
        self.legacyKey = nil
        self.legacyGlobalStore = nil
        self.adoptionDefaults = nil
        self.adoptionFlagKey = nil
        self.ownsLegacyPlaintext = false
        self.ephemeralMemoKey = Self.ephemeralMemoKey(for: storage)
    }

    /// The storage key for one app key's identity (UserDefaults) and the
    /// Keychain account used alongside the default service. The app key is
    /// trimmed so a whitespace-padded value cannot mint an identity alias
    /// distinct from its trimmed form (SEC-22); a key that remains blank or
    /// otherwise violates ``AppKeyGrammar`` is inert here — dispatch rejects
    /// it before any network call — but hosts should pass the same trimmed
    /// key to ``init(appKey:)`` as to ``FeedbackClientConfiguration``.
    static func scopedKey(for appKey: String) -> String {
        "\(defaultKey).\(AppKeyGrammar.normalized(appKey))"
    }

    /// The `UserDefaults` flag key marking a scoped store's one-shot legacy
    /// adoption as done. Trimmed exactly like ``scopedKey(for:)`` so the flag
    /// always tracks the store whose account it names (SEC-22).
    static func legacyAdoptionFlagKey(for appKey: String) -> String {
        "\(defaultKey).\(AppKeyGrammar.normalized(appKey)).legacyAdopted"
    }

    /// Deletes the stored identity and reports whether the deletion was confirmed.
    /// The next ``token`` access mints and persists a fresh UUID.
    ///
    /// Use this to support in-app "delete my data" actions, or to drop a
    /// rotated identity — ``FeedbackClient/eraseMyData(store:)`` calls it
    /// automatically after a successful erasure, because the server stops
    /// accepting the old token immediately.
    ///
    /// - Returns: `true` if the backing store successfully deleted the token
    ///   or confirmed no token was present; `false` if the deletion failed
    ///   (e.g. locked Keychain).
    @discardableResult
    public func reset() -> Bool {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        let confirmed = storage.deleteConfirmed()
        if confirmed {
            // A confirmed erasure ends the current run: the next read mints
            // and persists a fresh identity instead of resurrecting the
            // pre-reset ephemeral one (issue #567). A failed reset keeps the
            // memo, because the run it belongs to is still unresolved.
            Self.ephemeralMemo.drop(forKey: ephemeralMemoKey)
        }
        return confirmed
    }

    /// Returns the existing token, or generates and persists a new UUID on first access.
    ///
    /// Synchronized across threads and instances via double-checked locking so concurrent
    /// first accesses always resolve and persist the same identity. When the backing
    /// storage cannot confirm a write (e.g. an inaccessible Keychain before first
    /// unlock), the returned token is ephemeral: nothing is persisted and the adoption
    /// flag is left untouched. While the store stays unresolved, every read serves the
    /// same ephemeral token — memoized per backing store for the process lifetime
    /// (issue #567) — so one logical operation that resolves the identity more than
    /// once presents a single end-user identity instead of a rotating one. Resolution
    /// itself is retried on every read and the memo never shadows a durable identity:
    /// it is dropped as soon as a read resolves a stored token, a write is confirmed,
    /// or a confirmed ``reset()`` erases the item, after which the next read mints and
    /// persists a fresh UUID exactly as before.
    ///
    /// The same holds when the backing storage cannot be *read* (SEC-7): an
    /// inaccessible read does not prove the store is empty, so no write is
    /// attempted at all — a confirmed write could only land on top of the
    /// stored item (`errSecDuplicateItem` → `SecItemUpdate`) and would
    /// permanently replace the end user's identity with a fresh UUID. The
    /// stored identity wins again as soon as the store becomes readable.
    ///
    /// Likewise, an inaccessible read from the legacy global store (SEC-18)
    /// keeps adoption suspended: no write is attempted, the adoption flag
    /// remains uncommitted, and the memoized ephemeral token is served so the
    /// stored legacy identity is not permanently forfeited.
    public var token: String {
        if let existing = readableStoredToken() {
            removeLegacyPlaintextIfOwned()
            Self.ephemeralMemo.drop(forKey: ephemeralMemoKey)
            return existing
        }

        Self.processLock.lock()
        defer { Self.processLock.unlock() }

        let readAfterLock = storage.loadResult()
        if case .found(let existing) = readAfterLock, !existing.isEmpty {
            removeLegacyPlaintextIfOwned()
            Self.ephemeralMemo.drop(forKey: ephemeralMemoKey)
            return existing
        }

        if case .inaccessible = readAfterLock {
            // The item is present but unreadable (locked Keychain, transient
            // status, undecodable contents). Never write behind its back;
            // serve the process-stable ephemeral token and let the next read
            // retry (issue #567).
            return Self.ephemeralMemo.serve(forKey: ephemeralMemoKey)
        }

        switch adoptLegacyIdentityOnce() {
        case .adopted(let inherited):
            return inherited
        case .inaccessible:
            // The legacy global item is present but unreadable (SEC-18).
            // Never mint or persist a fresh identity behind its back; serve
            // the process-stable ephemeral token and let the next read retry.
            return Self.ephemeralMemo.serve(forKey: ephemeralMemoKey)
        case .notFound:
            break
        }

        // The store verifiably holds no token and no legacy identity is
        // adoptable, so minting is authorized. Serve the already-memoized
        // ephemeral token when one exists, so a run whose writes keep
        // failing still presents one identity while persistence keeps
        // retrying on every read.
        let new = Self.ephemeralMemo.serve(forKey: ephemeralMemoKey)
        guard storage.saveConfirmed(new) else {
            // The write could not be confirmed; the token stays memoized as
            // this store's ephemeral identity and adoption stays retryable
            // rather than serving an identity that exists nowhere.
            return new
        }
        markAdoptionComplete()
        removeLegacyPlaintextIfOwned()
        return new
    }

    /// The stored token when the backing storage reports a readable,
    /// non-empty one, or `nil` when the store answered "absent" or could not
    /// be read (SEC-7).
    private func readableStoredToken() -> String? {
        if case .found(let existing) = storage.loadResult(), !existing.isEmpty {
            return existing
        }
        return nil
    }

    private enum LegacyAdoptionResult: Sendable, Equatable {
        case adopted(String)
        case inaccessible
        case notFound
    }

    /// Copies the legacy global identity into this store exactly once.
    ///
    /// Scoped stores check the Keychain-held global identity first (the
    /// authoritative location since the plaintext-to-Keychain migration),
    /// then the pre-Keychain `UserDefaults` plaintext. The adoption flag's
    /// invariant is "a legacy identity was successfully persisted into this
    /// store", not "an adoption attempt was made": the flag is committed only
    /// after ``TokenStorage/saveConfirmed(_:)`` confirms the write, so a
    /// transiently inaccessible Keychain keeps adoption retryable instead of
    /// permanently rotating the identity.
    ///
    /// The same holds when reading the legacy global store (SEC-18): an
    /// inaccessible read does not prove the store is empty, so adoption is
    /// suspended without committing the flag or minting a new identity. The
    /// inherited value is still served for the current read when the write
    /// fails, which preserves the one-shot guarantee against *successful*
    /// adoption.
    private func adoptLegacyIdentityOnce() -> LegacyAdoptionResult {
        if let adoptionDefaults, let adoptionFlagKey,
           adoptionDefaults.bool(forKey: adoptionFlagKey) {
            return .notFound
        }

        if let legacyGlobalStore {
            switch legacyGlobalStore.loadResult() {
            case .found(let inherited) where !inherited.isEmpty:
                guard storage.saveConfirmed(inherited) else {
                    return .adopted(inherited)
                }
                markAdoptionComplete()
                return .adopted(inherited)
            case .inaccessible:
                return .inaccessible
            case .found, .notFound:
                break
            }
        }

        if let legacyUserDefaults,
           let legacyKey,
           let inherited = legacyUserDefaults.string(forKey: legacyKey),
           !inherited.isEmpty {
            guard storage.saveConfirmed(inherited) else {
                return .adopted(inherited)
            }
            if ownsLegacyPlaintext {
                legacyUserDefaults.removeObject(forKey: legacyKey)
            }
            markAdoptionComplete()
            return .adopted(inherited)
        }

        return .notFound
    }

    /// Drops the memoized ephemeral token — the store now verifiably holds a
    /// durable identity that must not be shadowed if the store later becomes
    /// unreadable — and commits the one-shot adoption flag. Only called once
    /// the store verifiably holds the identity just persisted; the flag part
    /// is a no-op for `.shared`, whose plaintext source self-destructs on
    /// adoption.
    private func markAdoptionComplete() {
        Self.ephemeralMemo.drop(forKey: ephemeralMemoKey)
        guard let adoptionDefaults, let adoptionFlagKey else { return }
        adoptionDefaults.set(true, forKey: adoptionFlagKey)
    }

    private func removeLegacyPlaintextIfOwned() {
        guard ownsLegacyPlaintext, let legacyUserDefaults, let legacyKey else { return }
        legacyUserDefaults.removeObject(forKey: legacyKey)
    }
}
