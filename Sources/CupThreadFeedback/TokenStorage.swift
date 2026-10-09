import Foundation
import Security

/// Outcome of reading a token from a backing store (SEC-7).
///
/// The distinction matters for identity safety: only ``notFound`` verifiably
/// means "no token is stored" and may authorize minting a fresh identity.
/// ``inaccessible(_:)`` covers every read that could not be confirmed — a
/// locked Keychain (`errSecInteractionNotAllowed` before first unlock),
/// another transient Security-layer status, or an item whose contents cannot
/// be decoded — where an item may still exist. Callers must never write over
/// an ``inaccessible(_:)`` read: doing so can replace the stored identity
/// with a newly generated one and permanently orphan the end user's history.
enum TokenLoadResult: Sendable, Equatable {
    /// The store returned this readable, non-empty token.
    case found(String)
    /// The backing store verifiably holds no token (`errSecItemNotFound`,
    /// or an item whose stored value is empty).
    case notFound
    /// The read failed with the given status; a token may or may not be
    /// stored. The identity must be treated as present-but-unreadable.
    case inaccessible(OSStatus)
}

/// Persistent storage mechanism for user tokens.
protocol TokenStorage: Sendable {
    /// Loads the stored token, or returns `nil` when no readable token is
    /// stored.
    ///
    /// Convenience for ``loadResult()`` for stores that cannot distinguish
    /// "absent" from "unreadable". Backing stores that can observe read
    /// failures (the Keychain) implement ``loadResult()`` and derive this
    /// from it, so a locked Keychain keeps returning `nil` here without
    /// being mistaken for an empty store by legacy call sites.
    func load() -> String?

    /// Reads the stored token, distinguishing a confirmed absence from a
    /// transiently unreadable backing store (SEC-7).
    ///
    /// The default treats any `nil` from ``load()`` as a confirmed absence;
    /// storages whose reads can fail transiently must override this.
    func loadResult() -> TokenLoadResult

    /// Persists the specified token.
    ///
    /// Best-effort: write failures may be ignored. Call paths that must not
    /// lose an identity (first mint, one-shot legacy adoption) use
    /// ``saveConfirmed(_:)`` instead.
    func save(_ token: String)

    /// Persists the token and reports whether the write was confirmed durable.
    ///
    /// The default delegates to ``save(_:)`` and reports success, which is
    /// accurate for storages that cannot fail. Backing stores that can
    /// observe write failures (the Keychain) override this. One-shot flags
    /// must only be committed after this returns `true`.
    @discardableResult
    func saveConfirmed(_ token: String) -> Bool

    /// Deletes any stored token.
    func delete()
}

extension TokenStorage {
    /// Default read classification for stores that can only answer
    /// "token or no token": a `nil` from ``load()`` is treated as a
    /// confirmed absence.
    func loadResult() -> TokenLoadResult {
        load().map(TokenLoadResult.found) ?? .notFound
    }

    func saveConfirmed(_ token: String) -> Bool {
        save(token)
        return true
    }
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

    /// Test seam standing in for `SecItemAdd`.
    typealias SecItemAddOperation = @Sendable (CFDictionary) -> OSStatus
    /// Test seam standing in for `SecItemUpdate`.
    typealias SecItemUpdateOperation = @Sendable (CFDictionary, CFDictionary) -> OSStatus
    /// Test seam standing in for `SecItemCopyMatching`.
    typealias SecItemCopyOperation = @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus

    let service: String
    let account: String
    let accessibility: CFString
    private let addItem: SecItemAddOperation
    private let updateItem: SecItemUpdateOperation
    private let copyItem: SecItemCopyOperation

    init(
        service: String = KeychainTokenStorage.defaultService,
        account: String = UserTokenStore.defaultKey,
        accessibility: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ) {
        self.service = service
        self.account = account
        self.accessibility = accessibility
        self.addItem = { SecItemAdd($0, nil) }
        self.updateItem = { SecItemUpdate($0, $1) }
        self.copyItem = { SecItemCopyMatching($0, $1) }
    }

    /// Scripts `SecItemAdd`/`SecItemUpdate`/`SecItemCopyMatching` outcomes so
    /// the read- and write-status handling is unit-testable without touching
    /// the real Keychain.
    init(
        service: String,
        account: String,
        accessibility: CFString,
        addItem: @escaping SecItemAddOperation,
        updateItem: @escaping SecItemUpdateOperation,
        copyItem: @escaping SecItemCopyOperation = { SecItemCopyMatching($0, $1) }
    ) {
        self.service = service
        self.account = account
        self.accessibility = accessibility
        self.addItem = addItem
        self.updateItem = updateItem
        self.copyItem = copyItem
    }

    func load() -> String? {
        if case .found(let token) = loadResult() { return token }
        return nil
    }

    /// Classifies the Keychain read so only `errSecItemNotFound` counts as
    /// "no token stored" (SEC-7).
    ///
    /// `errSecInteractionNotAllowed` (device locked before first unlock),
    /// missing-entitlement and every other non-success status read back as
    /// ``TokenLoadResult/inaccessible(_:)`` even though an item may be
    /// stored, and `errSecSuccess` with contents that are not a non-empty
    /// UTF-8 string does too (reported as `errSecDecode`) — writing over any
    /// of those could destroy the stored identity.
    func loadResult() -> TokenLoadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = copyItem(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            return status == errSecItemNotFound ? .notFound : .inaccessible(status)
        }
        guard let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return .inaccessible(errSecDecode)
        }
        // An item holding an empty value carries no identity, so replacing
        // it on the next mint loses nothing.
        return token.isEmpty ? .notFound : .found(token)
    }

    func save(_ token: String) {
        _ = saveConfirmed(token)
    }

    /// Persists the token and reports whether the Keychain confirmed it.
    ///
    /// Returns `false` for every `SecItemAdd` status other than
    /// `errSecSuccess` (including inaccessible-Keychain failures such as
    /// `errSecInteractionNotAllowed`), and for the duplicate-item path when
    /// `SecItemUpdate` does not return `errSecSuccess`.
    @discardableResult
    func saveConfirmed(_ token: String) -> Bool {
        guard let data = token.data(using: .utf8) else { return false }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        var addAttributes = baseQuery
        addAttributes[kSecValueData as String] = data
        addAttributes[kSecAttrAccessible as String] = accessibility

        let status = addItem(addAttributes as CFDictionary)
        guard status == errSecDuplicateItem else {
            return status == errSecSuccess
        }
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility
        ]
        return updateItem(baseQuery as CFDictionary, updateAttributes as CFDictionary) == errSecSuccess
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
