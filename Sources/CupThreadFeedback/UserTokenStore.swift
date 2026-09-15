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
///
/// Pass the token wherever the SDK asks for a `userToken`:
///
/// ```swift
/// FeatureRequestsView(client: client, userToken: UserTokenStore.shared.token)
/// ```
public final class UserTokenStore: @unchecked Sendable {
    /// The shared store, backed by the system Keychain with legacy `UserDefaults` migration.
    public static let shared = UserTokenStore()

    /// The default key used in storage to identify the anonymous token.
    static let defaultKey = "com.cupthread.featureRequestUserToken"

    private static let processLock = NSLock()

    private let storage: any TokenStorage
    private let legacyUserDefaults: UserDefaults?
    private let legacyKey: String?

    /// Initializes a token store backed by a custom storage and optional migration source.
    /// Internal to allow unit tests to pass storage doubles and test migration.
    init(
        storage: any TokenStorage,
        legacyUserDefaults: UserDefaults? = nil,
        legacyKey: String? = nil
    ) {
        self.storage = storage
        self.legacyUserDefaults = legacyUserDefaults
        self.legacyKey = legacyKey
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

    /// Initializes a token store backed directly by `UserDefaults`.
    /// Internal to allow unit tests to pass isolated `UserDefaults` and keys.
    init(userDefaults: UserDefaults = .standard, key: String = UserTokenStore.defaultKey) {
        self.storage = UserDefaultsTokenStorage(userDefaults: userDefaults, key: key)
        self.legacyUserDefaults = nil
        self.legacyKey = nil
    }

    /// Returns the existing token, or generates and persists a new UUID on first access.
    ///
    /// Synchronized across threads and instances via double-checked locking so concurrent
    /// first accesses always resolve and persist the same identity.
    public var token: String {
        if let existing = storage.load(), !existing.isEmpty {
            if let legacyUserDefaults, let legacyKey {
                legacyUserDefaults.removeObject(forKey: legacyKey)
            }
            return existing
        }

        Self.processLock.lock()
        defer { Self.processLock.unlock() }

        if let existing = storage.load(), !existing.isEmpty {
            if let legacyUserDefaults, let legacyKey {
                legacyUserDefaults.removeObject(forKey: legacyKey)
            }
            return existing
        }

        if let legacyUserDefaults,
           let legacyKey,
           let legacyToken = legacyUserDefaults.string(forKey: legacyKey),
           !legacyToken.isEmpty {
            storage.save(legacyToken)
            legacyUserDefaults.removeObject(forKey: legacyKey)
            return legacyToken
        }

        if let legacyUserDefaults, let legacyKey {
            legacyUserDefaults.removeObject(forKey: legacyKey)
        }

        let new = UUID().uuidString
        storage.save(new)
        return new
    }
}
