import Foundation

/// Persistent storage mechanism for subscribed changelog email addresses.
typealias ChangelogSubscriptionStorage = TokenStorage

/// Generic Keychain-backed string storage.
typealias KeychainStringStorage = KeychainTokenStorage

/// Thread-safe in-memory subscription storage for unit testing.
final class InMemorySubscriptionStorage: ChangelogSubscriptionStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEmail: String?

    init(initialEmail: String? = nil) {
        self.storedEmail = initialEmail
    }

    func load() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storedEmail
    }

    func save(_ email: String) {
        lock.lock()
        defer { lock.unlock() }
        storedEmail = email
    }

    func delete() {
        lock.lock()
        defer { lock.unlock() }
        storedEmail = nil
    }
}

/// Thread-safe persistent store for the changelog email-subscription state.
///
/// Remembers the email address subscribed to changelog notifications in the
/// system Keychain (`kSecClassGenericPassword`, scoped to device-only
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and excluded from unencrypted
/// device backups) under service `"com.cupthread.changelogEmail"` and account
/// `"com.cupthread.changelog.subscribedEmail.<appKey>"`, following the same
/// per-app-key scoping as `ChangelogSeenStore`. On first access, any legacy address
/// stored in `UserDefaults` is automatically migrated to the Keychain and deleted
/// from defaults.
///
/// The backend exposes no subscription-status query, so this local record is
/// the only way SDK surfaces can avoid re-prompting already-subscribed users
/// with a blank form on every launch. Subscriptions made outside the SDK
/// (web console) and unsubscriptions made via an emailed link are not
/// observed; the next successful in-app subscribe re-records the address.
final class ChangelogSubscriptionStore: @unchecked Sendable {
    /// Key prefix used in `UserDefaults` and Keychain account, followed by the app key.
    static let keyPrefix = "com.cupthread.changelog.subscribedEmail."

    /// Keychain service identifier used for changelog subscription email storage.
    static let keychainService = "com.cupthread.changelogEmail"

    let appKey: String
    let storageKey: String

    private let storage: any ChangelogSubscriptionStorage
    private let legacyUserDefaults: UserDefaults?

    private let lock = NSLock()

    var userDefaults: UserDefaults {
        legacyUserDefaults ?? .standard
    }

    init(
        appKey: String,
        storage: (any ChangelogSubscriptionStorage)? = nil,
        legacyUserDefaults: UserDefaults? = .standard
    ) {
        let storageKey = Self.keyPrefix + appKey
        self.appKey = appKey
        self.storageKey = storageKey
        self.storage = storage ?? KeychainTokenStorage(
            service: Self.keychainService,
            account: storageKey
        )
        self.legacyUserDefaults = legacyUserDefaults
    }

    convenience init(appKey: String, userDefaults: UserDefaults) {
        self.init(
            appKey: appKey,
            storage: nil,
            legacyUserDefaults: userDefaults
        )
    }

    /// The remembered subscribed email, or `nil` when nothing is recorded.
    func subscribedEmail() -> String? {
        lock.lock()
        defer { lock.unlock() }

        if let existing = storage.load(), !existing.isEmpty {
            removeLegacyPlaintext()
            return existing
        }

        if let legacy = legacyUserDefaults?.string(forKey: storageKey) {
            let trimmed = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                removeLegacyPlaintext()
                return nil
            }
            guard storage.saveConfirmed(trimmed) else {
                return trimmed
            }
            removeLegacyPlaintext()
            return trimmed
        }

        return nil
    }

    /// Records the subscribed email, trimmed. Whitespace-only input is ignored.
    func persist(email: String) {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        storage.save(trimmed)
        removeLegacyPlaintext()
    }

    /// Removes the remembered subscription.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        storage.delete()
        removeLegacyPlaintext()
    }

    private func removeLegacyPlaintext() {
        legacyUserDefaults?.removeObject(forKey: storageKey)
    }
}
