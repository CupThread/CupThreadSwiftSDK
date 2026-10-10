import Foundation

/// The remembered changelog-subscription state for one app key.
///
/// Subscriptions are double opt-in: `subscribeToChangelog` only creates a
/// *pending* record and the address starts receiving changelog emails after
/// the emailed single-use confirmation link is submitted. Remembering the
/// phase keeps SDK surfaces from claiming "emails on" for a subscription
/// that was never confirmed (issue #273).
struct ChangelogSubscriptionRecord: Equatable, Sendable, Codable {
    /// Double-opt-in phase of the remembered subscription.
    enum State: Equatable, Sendable {
        /// Subscribe succeeded; the emailed confirmation is still outstanding.
        case pending(since: Date)
        /// Confirmed — or recorded by an SDK version predating the phase
        /// distinction, whose bare-email storage migrates here.
        case confirmed

        /// Whether the emailed confirmation is still outstanding.
        var isPending: Bool {
            if case .pending = self { return true }
            return false
        }
    }

    let email: String
    let state: State

    init(email: String, state: State) {
        self.email = email
        self.state = state
    }

    private enum CodingKeys: String, CodingKey {
        case email, state, since
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        email = try container.decode(String.self, forKey: .email)
        if try container.decode(String.self, forKey: .state) == "pending" {
            state = .pending(
                since: try container.decodeIfPresent(Date.self, forKey: .since)
                    ?? Date(timeIntervalSince1970: 0)
            )
        } else {
            state = .confirmed
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(email, forKey: .email)
        switch state {
        case .pending(let since):
            try container.encode("pending", forKey: .state)
            try container.encode(since, forKey: .since)
        case .confirmed:
            try container.encode("confirmed", forKey: .state)
        }
    }
}

/// Persistent storage mechanism for remembered subscription records (SEC-9):
/// records persist as serialized JSON strings through the Keychain-backed
/// token storage.
typealias ChangelogSubscriptionStorage = TokenStorage

/// Generic Keychain-backed string storage.
typealias KeychainStringStorage = KeychainTokenStorage

/// Thread-safe in-memory subscription storage for unit testing.
final class InMemorySubscriptionStorage: ChangelogSubscriptionStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String?

    init(initialEmail: String? = nil) {
        self.storedValue = initialEmail
    }

    func load() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func save(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        storedValue = value
    }

    func delete() {
        lock.lock()
        defer { lock.unlock() }
        storedValue = nil
    }
}

/// Thread-safe persistent store for the changelog email-subscription state.
///
/// Remembers the subscription for this app key — address plus its
/// double-opt-in phase (`ChangelogSubscriptionRecord`) — in the system
/// Keychain (`kSecClassGenericPassword`, scoped to device-only
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and excluded from
/// unencrypted device backups) under service `"com.cupthread.changelogEmail"`
/// and account `"com.cupthread.changelog.subscribedEmail.<appKey>"`, following
/// the same per-app-key scoping as `ChangelogSeenStore`. On first access any
/// legacy value — a bare address or a serialized record in `UserDefaults`, or
/// a bare address written to the Keychain by the phase-unaware build — is
/// migrated forward and the plaintext removed from defaults.
///
/// The backend exposes no subscription-status query, so this local record is
/// the only way SDK surfaces can avoid re-prompting already-subscribed users
/// and can honestly reflect the pending double-opt-in phase. Subscriptions
/// confirmed out-of-band (web console) and unsubscriptions made via an
/// emailed link are not observed; the next successful in-app subscribe
/// re-records the address.
final class ChangelogSubscriptionStore: @unchecked Sendable {
    /// Key prefix used for the Keychain account and legacy `UserDefaults`
    /// key, followed by the app key.
    static let keyPrefix = "com.cupthread.changelog.subscribedEmail."

    /// Keychain service identifier used for changelog subscription storage.
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

    private final class MemoryCache: @unchecked Sendable {
        private let lock = NSLock()
        private var records: [String: ChangelogSubscriptionRecord] = [:]

        func record(for key: String) -> ChangelogSubscriptionRecord? {
            lock.lock()
            defer { lock.unlock() }
            return records[key]
        }

        func set(_ record: ChangelogSubscriptionRecord?, for key: String) {
            lock.lock()
            defer { lock.unlock() }
            if let record {
                records[key] = record
            } else {
                records.removeValue(forKey: key)
            }
        }

        func reset() {
            lock.lock()
            defer { lock.unlock() }
            records.removeAll()
        }
    }

    private static let cache = MemoryCache()

    /// Resets the in-memory cache of subscription records (for test isolation).
    static func resetMemoryCache() {
        cache.reset()
    }

    private func cachedRecord() -> ChangelogSubscriptionRecord? {
        Self.cache.record(for: storageKey)
    }

    private func updateMemoryCache(with record: ChangelogSubscriptionRecord?) {
        Self.cache.set(record, for: storageKey)
    }

    /// The remembered subscription with its double-opt-in phase, or `nil`
    /// when nothing is recorded.
    func subscriptionRecord() -> ChangelogSubscriptionRecord? {
        lock.lock()
        defer { lock.unlock() }

        switch storage.loadResult() {
        case .found(let existing) where !existing.isEmpty:
            // A bare address here was written by the phase-unaware Keychain
            // build (SEC-9 before #273); it reads back as confirmed.
            removeLegacyPlaintext()
            let record = Self.record(fromStoredValue: existing)
            updateMemoryCache(with: record)
            return record

        case .found:
            removeLegacyPlaintext()
            updateMemoryCache(with: nil)
            return nil

        case .notFound:
            if let legacy = legacyUserDefaults?.string(forKey: storageKey) {
                // Pre-SEC-9 defaults: a bare address or a serialized record from
                // the phase-aware defaults build (#273). Whitespace-only values
                // are garbage, not a subscription: purge and report nothing.
                let trimmed = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let record = Self.record(fromStoredValue: trimmed) else {
                    removeLegacyPlaintext()
                    updateMemoryCache(with: nil)
                    return nil
                }
                if storage.saveConfirmed(trimmed) {
                    removeLegacyPlaintext()
                }
                updateMemoryCache(with: record)
                return record
            }
            updateMemoryCache(with: nil)
            return nil

        case .inaccessible:
            // Backing storage is transiently unreadable (e.g. Keychain locked
            // before first unlock). Do not purge legacy plaintext or commit writes.
            if let legacy = legacyUserDefaults?.string(forKey: storageKey) {
                let trimmed = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
                if let record = Self.record(fromStoredValue: trimmed) {
                    return record
                }
            }
            return cachedRecord()
        }
    }

    /// The remembered subscription address regardless of its phase, or `nil`
    /// when nothing is recorded.
    func subscribedEmail() -> String? {
        subscriptionRecord()?.email
    }

    /// Records the subscription with its double-opt-in phase. The address is
    /// trimmed; whitespace-only input is ignored.
    func persist(record: ChangelogSubscriptionRecord) {
        let trimmed = record.email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = try? JSONEncoder().encode(
                  ChangelogSubscriptionRecord(email: trimmed, state: record.state)
              ),
              let serialized = String(data: data, encoding: .utf8) else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        guard storage.saveConfirmed(serialized) else {
            return
        }
        updateMemoryCache(with: ChangelogSubscriptionRecord(email: trimmed, state: record.state))
        removeLegacyPlaintext()
    }

    /// Removes the remembered subscription.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        storage.delete()
        updateMemoryCache(with: nil)
        removeLegacyPlaintext()
    }

    private func removeLegacyPlaintext() {
        legacyUserDefaults?.removeObject(forKey: storageKey)
    }

    private static func record(fromStoredValue raw: String?) -> ChangelogSubscriptionRecord? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(ChangelogSubscriptionRecord.self, from: data) {
            return decoded
        }
        return ChangelogSubscriptionRecord(email: trimmed, state: .confirmed)
    }
}
