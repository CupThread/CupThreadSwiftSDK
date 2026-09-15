import Foundation

/// Thread-safe and bounded persistent store for tracking seen changelog versions.
///
/// Stores seen version labels and entry IDs in `UserDefaults` under
/// `"com.cupthread.changelog.seenVersions.<appKey>"`.
///
/// Thread safety is ensured with an `NSLock`.
/// Storage is bounded to at most `maxCapacity` (default 64) entries, pruning oldest entries first
/// to prevent unbounded `UserDefaults` growth.
final class ChangelogSeenStore: @unchecked Sendable {
    /// Default maximum number of seen version records retained per app key.
    static let defaultMaxCapacity = 64

    /// Key prefix used in `UserDefaults`.
    static let keyPrefix = "com.cupthread.changelog.seenVersions."

    private final class StoreRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var stores: [String: ChangelogSeenStore] = [:]

        func store(
            for appKey: String,
            userDefaults: UserDefaults,
            maxCapacity: Int
        ) -> ChangelogSeenStore {
            lock.lock()
            defer { lock.unlock() }
            if let existing = stores[appKey] {
                return existing
            }
            let store = ChangelogSeenStore(appKey: appKey, userDefaults: userDefaults, maxCapacity: maxCapacity)
            stores[appKey] = store
            return store
        }

        func register(_ store: ChangelogSeenStore, for appKey: String) {
            lock.lock()
            defer { lock.unlock() }
            stores[appKey] = store
        }

        func reset() {
            lock.lock()
            defer { lock.unlock() }
            stores.removeAll()
        }
    }

    private static let registry = StoreRegistry()

    /// Retrieves or creates the shared store for the given `appKey`.
    static func shared(
        for appKey: String,
        userDefaults: UserDefaults = .standard,
        maxCapacity: Int = defaultMaxCapacity
    ) -> ChangelogSeenStore {
        registry.store(for: appKey, userDefaults: userDefaults, maxCapacity: maxCapacity)
    }

    /// Registers a custom store for the given `appKey` (primarily for testing).
    static func register(_ store: ChangelogSeenStore, for appKey: String) {
        registry.register(store, for: appKey)
    }

    /// Resets the in-memory registry of stores (for test isolation).
    static func resetRegistry() {
        registry.reset()
    }

    let appKey: String
    let maxCapacity: Int
    let userDefaults: UserDefaults
    let storageKey: String

    private let lock = NSLock()
    private var _writeCount: Int = 0

    /// Returns the number of mutations written to `UserDefaults` by this store instance.
    var writeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _writeCount
    }

    init(
        appKey: String,
        userDefaults: UserDefaults = .standard,
        maxCapacity: Int = ChangelogSeenStore.defaultMaxCapacity
    ) {
        self.appKey = appKey
        self.userDefaults = userDefaults
        self.maxCapacity = max(1, maxCapacity)
        self.storageKey = Self.keyPrefix + appKey
    }

    /// Checks if the version has already been recorded as seen.
    func hasSeen(_ version: String) -> Bool {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        let seen = userDefaults.stringArray(forKey: storageKey) ?? []
        return seen.contains(trimmed)
    }

    /// Records the given version as seen.
    ///
    /// If already seen, this is an idempotent no-op that performs no writes.
    /// New marks are appended, and if the count exceeds `maxCapacity`, the oldest
    /// marks are pruned.
    func markSeen(_ version: String) {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        var seen = userDefaults.stringArray(forKey: storageKey) ?? []
        if seen.contains(trimmed) {
            if seen.count > maxCapacity {
                seen.removeFirst(seen.count - maxCapacity)
                userDefaults.set(seen, forKey: storageKey)
                _writeCount += 1
            }
            return
        }

        seen.append(trimmed)
        if seen.count > maxCapacity {
            seen.removeFirst(seen.count - maxCapacity)
        }
        userDefaults.set(seen, forKey: storageKey)
        _writeCount += 1
    }

    /// Records both an entry ID and an optional version label as seen in a single atomic pass.
    func markSeen(id: String, versionLabel: String?) {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLabel = versionLabel?.trimmingCharacters(in: .whitespacesAndNewlines)

        lock.lock()
        defer { lock.unlock() }

        var seen = userDefaults.stringArray(forKey: storageKey) ?? []
        var mutated = false

        if !trimmedID.isEmpty && !seen.contains(trimmedID) {
            seen.append(trimmedID)
            mutated = true
        }

        if let trimmedLabel, !trimmedLabel.isEmpty && !seen.contains(trimmedLabel) {
            seen.append(trimmedLabel)
            mutated = true
        }

        if seen.count > maxCapacity {
            seen.removeFirst(seen.count - maxCapacity)
            mutated = true
        }

        if mutated {
            userDefaults.set(seen, forKey: storageKey)
            _writeCount += 1
        }
    }

    /// Returns the array of seen versions currently persisted in storage.
    func storedVersions() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return userDefaults.stringArray(forKey: storageKey) ?? []
    }

    /// Removes all stored seen versions for this app key.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        userDefaults.removeObject(forKey: storageKey)
        _writeCount += 1
    }
}
