import Foundation

/// Persists a stable anonymous user token across app launches.
/// Used to track vote state and own pending requests without requiring authentication.
///
/// The token is a plain UUID securely stored in the system Keychain (`kSecClassGenericPassword`).
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

    private static let processLock = NSLock()

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
        self.storage = UserDefaultsTokenStorage(userDefaults: userDefaults, key: key)
        self.legacyUserDefaults = nil
        self.legacyKey = nil
        self.legacyGlobalStore = nil
        self.adoptionDefaults = nil
        self.adoptionFlagKey = nil
        self.ownsLegacyPlaintext = false
    }

    /// The storage key for one app key's identity (UserDefaults) and the
    /// Keychain account used alongside the default service.
    static func scopedKey(for appKey: String) -> String {
        "\(defaultKey).\(appKey)"
    }

    /// The `UserDefaults` flag key marking a scoped store's one-shot legacy
    /// adoption as done.
    static func legacyAdoptionFlagKey(for appKey: String) -> String {
        "\(defaultKey).\(appKey).legacyAdopted"
    }

    /// Deletes the stored identity. The next ``token`` access mints and
    /// persists a fresh UUID.
    ///
    /// Use this to support in-app "delete my data" actions, or to drop a
    /// rotated identity — ``FeedbackClient/eraseMyData(store:)`` calls it
    /// automatically after a successful erasure, because the server stops
    /// accepting the old token immediately.
    public func reset() {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        storage.delete()
    }

    /// Returns the existing token, or generates and persists a new UUID on first access.
    ///
    /// Synchronized across threads and instances via double-checked locking so concurrent
    /// first accesses always resolve and persist the same identity. When the backing
    /// storage cannot confirm a write (e.g. an inaccessible Keychain before first
    /// unlock), the returned token is ephemeral: nothing is persisted, the adoption
    /// flag is left untouched, and the next read retries so the identity never rotates.
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
    /// remains uncommitted, and an ephemeral UUID is served so the stored
    /// legacy identity is not permanently forfeited.
    public var token: String {
        if let existing = readableStoredToken() {
            removeLegacyPlaintextIfOwned()
            return existing
        }

        Self.processLock.lock()
        defer { Self.processLock.unlock() }

        let readAfterLock = storage.loadResult()
        if case .found(let existing) = readAfterLock, !existing.isEmpty {
            removeLegacyPlaintextIfOwned()
            return existing
        }

        if case .inaccessible = readAfterLock {
            // The item is present but unreadable (locked Keychain, transient
            // status, undecodable contents). Never write behind its back;
            // serve an ephemeral token and let the next read retry.
            return UUID().uuidString
        }

        switch adoptLegacyIdentityOnce() {
        case .adopted(let inherited):
            return inherited
        case .inaccessible:
            // The legacy global item is present but unreadable (SEC-18).
            // Never mint or persist a fresh identity behind its back;
            // serve an ephemeral token and let the next read retry.
            return UUID().uuidString
        case .notFound:
            break
        }

        let new = UUID().uuidString
        guard storage.saveConfirmed(new) else {
            // The write could not be confirmed; serve an ephemeral token and
            // leave adoption retryable rather than minting an identity that
            // exists nowhere.
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

    /// Commits the one-shot adoption flag. Only called once the store
    /// verifiably holds the identity just persisted; a no-op for `.shared`,
    /// whose plaintext source self-destructs on adoption.
    private func markAdoptionComplete() {
        guard let adoptionDefaults, let adoptionFlagKey else { return }
        adoptionDefaults.set(true, forKey: adoptionFlagKey)
    }

    private func removeLegacyPlaintextIfOwned() {
        guard ownsLegacyPlaintext, let legacyUserDefaults, let legacyKey else { return }
        legacyUserDefaults.removeObject(forKey: legacyKey)
    }
}
