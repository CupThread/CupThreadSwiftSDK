import Foundation
import Security

/// Persistent storage mechanism for user tokens.
protocol TokenStorage: Sendable {
    /// Loads the stored token, or returns `nil` if no token has been saved.
    func load() -> String?

    /// Persists the specified token.
    func save(_ token: String)

    /// Deletes any stored token.
    func delete()
}

/// Token storage backed by `UserDefaults`.
///
/// Used for backwards-compatible test suites and suite isolation.
final class UserDefaultsTokenStorage: TokenStorage, @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let key: String

    init(userDefaults: UserDefaults = .standard, key: String = UserTokenStore.defaultKey) {
        self.userDefaults = userDefaults
        self.key = key
    }

    func load() -> String? {
        guard let value = userDefaults.string(forKey: key), !value.isEmpty else {
            return nil
        }
        return value
    }

    func save(_ token: String) {
        userDefaults.set(token, forKey: key)
    }

    func delete() {
        userDefaults.removeObject(forKey: key)
    }
}

/// Token storage backed by the Apple Keychain (`kSecClassGenericPassword`).
///
/// Scoped to this device (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) and isolated from
/// unencrypted device backups.
final class KeychainTokenStorage: TokenStorage, @unchecked Sendable {
    /// The default Keychain service identifier used by the SDK.
    static let defaultService = "com.cupthread.userToken"

    let service: String
    let account: String
    let accessibility: CFString

    init(
        service: String = KeychainTokenStorage.defaultService,
        account: String = UserTokenStore.defaultKey,
        accessibility: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ) {
        self.service = service
        self.account = account
        self.accessibility = accessibility
    }

    func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            return nil
        }
        return token
    }

    func save(_ token: String) {
        guard let data = token.data(using: .utf8) else { return }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        var addAttributes = baseQuery
        addAttributes[kSecValueData as String] = data
        addAttributes[kSecAttrAccessible as String] = accessibility

        let status = SecItemAdd(addAttributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: accessibility
            ]
            SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)
        }
    }

    func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

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
    /// Flags that the one-shot legacy adoption ran, so ``reset()`` is not
    /// undone by re-inheriting the (possibly rotated) global identity.
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
    /// first accesses always resolve and persist the same identity.
    public var token: String {
        if let existing = storage.load(), !existing.isEmpty {
            removeLegacyPlaintextIfOwned()
            return existing
        }

        Self.processLock.lock()
        defer { Self.processLock.unlock() }

        if let existing = storage.load(), !existing.isEmpty {
            removeLegacyPlaintextIfOwned()
            return existing
        }

        if let inherited = adoptLegacyIdentityOnce() {
            return inherited
        }

        let new = UUID().uuidString
        storage.save(new)
        removeLegacyPlaintextIfOwned()
        return new
    }

    /// Copies the legacy global identity into this store exactly once.
    ///
    /// Scoped stores check the Keychain-held global identity first (the
    /// authoritative location since the plaintext-to-Keychain migration),
    /// then the pre-Keychain `UserDefaults` plaintext. The adoption flag is
    /// written even when no legacy identity exists, so a later ``reset()``
    /// cannot be undone by re-inheriting a stale or rotated global token.
    private func adoptLegacyIdentityOnce() -> String? {
        let adoptionAlreadyDone: Bool
        if let adoptionDefaults, let adoptionFlagKey {
            if adoptionDefaults.bool(forKey: adoptionFlagKey) {
                adoptionAlreadyDone = true
            } else {
                adoptionDefaults.set(true, forKey: adoptionFlagKey)
                adoptionAlreadyDone = false
            }
        } else {
            // `.shared` has no flag: its plaintext source self-destructs on
            // adoption, which already makes the migration one-shot.
            adoptionAlreadyDone = false
        }

        guard !adoptionAlreadyDone else { return nil }

        if let legacyGlobalStore,
           let inherited = legacyGlobalStore.load(),
           !inherited.isEmpty {
            storage.save(inherited)
            return inherited
        }

        if let legacyUserDefaults,
           let legacyKey,
           let inherited = legacyUserDefaults.string(forKey: legacyKey),
           !inherited.isEmpty {
            storage.save(inherited)
            if ownsLegacyPlaintext {
                legacyUserDefaults.removeObject(forKey: legacyKey)
            }
            return inherited
        }

        return nil
    }

    private func removeLegacyPlaintextIfOwned() {
        guard ownsLegacyPlaintext, let legacyUserDefaults, let legacyKey else { return }
        legacyUserDefaults.removeObject(forKey: legacyKey)
    }
}
