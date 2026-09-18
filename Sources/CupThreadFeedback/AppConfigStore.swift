import Foundation

// MARK: - Last-good cache

/// Read/write storage behind the persisted configuration cache.
protocol SdkConfigCacheStorage: Sendable {
    /// Loads the cached payload for `key`, or `nil` when absent.
    func data(forKey key: String) -> Data?
    /// Persists `data` under `key`.
    func set(_ data: Data, forKey key: String)
}

/// `UserDefaults`-backed storage for the last-good configuration cache.
final class UserDefaultsConfigStorage: SdkConfigCacheStorage, @unchecked Sendable {
    private let defaults: UserDefaults

    init(userDefaults: UserDefaults) {
        self.defaults = userDefaults
    }

    func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    func set(_ data: Data, forKey key: String) {
        defaults.set(data, forKey: key)
    }
}

/// Persists the last successfully fetched ``SdkAppearance`` per app key.
///
/// Consulted only when a fetch fails: the cached theme, feature flags, and
/// overlay copy stay in force instead of rolling back to defaults, so console
/// kill-switches keep working through outages. The cache has no TTL — every
/// successful fetch overwrites it, and entries are namespaced per app key so
/// multiple apps in one process stay isolated.
final class SdkConfigCache: Sendable {
    /// Prefix of the `UserDefaults` keys holding cached appearances.
    static let keyPrefix = "com.cupthread.sdkConfigCache."

    private let storage: any SdkConfigCacheStorage
    private let key: String

    /// Creates a cache scoped to one app key.
    /// - Parameters:
    ///   - appKey: The CupThread app key that namespaces the entry.
    ///   - storage: The backing store; defaults to the standard
    ///     `UserDefaults`.
    init(
        appKey: String,
        storage: any SdkConfigCacheStorage = UserDefaultsConfigStorage(userDefaults: .standard)
    ) {
        self.storage = storage
        self.key = Self.keyPrefix + appKey
    }

    /// The persisted appearance for this app key, or `nil` when no fetch has
    /// ever succeeded (or the stored payload cannot be decoded).
    func cachedAppearance() -> SdkAppearance? {
        guard let data = storage.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SdkAppearance.self, from: data)
    }

    /// Overwrites the cached appearance after a successful fetch.
    func store(_ appearance: SdkAppearance) {
        guard let data = try? JSONEncoder().encode(appearance) else { return }
        storage.set(data, forKey: key)
    }
}

// MARK: - Short-TTL config cache

/// Shared, coalescing, short-TTL in-memory cache for the app configuration
/// (`GET /api/v1/public/config/{appKey}`).
///
/// Every ``FeedbackClient`` holds one store, and every configuration reader
/// goes through it: ``SdkConfigLoader`` (``CupThreadTheme`` and per-surface
/// gating), the feedback composer's attachment-limit lookup, the changelog
/// overlay paths, and ``FeedbackClient/cachedAppConfig()``. Concurrent readers
/// share a single in-flight request, and readers within the TTL window reuse
/// the last response, so presenting any number of SDK surfaces costs at most
/// one configuration GET per window per client — a re-presented sheet never
/// re-fetches, and a console-disabled surface gates before its content tasks
/// can fire their own requests.
///
/// The store is a lock-protected class rather than an actor because the
/// surface gate must resolve a warm cache *synchronously* during the first
/// body evaluation (``SdkConfigLoader`` reads it at init); an actor hop would
/// reintroduce the one-frame waiting placeholder the cache exists to remove.
///
/// Every success is also written through to the on-disk last-good
/// ``SdkConfigCache`` so a later failure can restore the last working
/// appearance (see ``SdkConfigStatus``). The in-memory TTL entry is never
/// seeded from disk: the disk cache has no fetch timestamp, and treating it
/// as fresh would silently suppress refreshes.
final class AppConfigStore: @unchecked Sendable {
    /// How long a fetched configuration is reused before the next read
    /// refetches. Short by design so console changes keep propagating quickly.
    static let defaultTTL: TimeInterval = 30

    private struct Entry {
        let config: PublicAppConfig
        let fetchedAt: Date
    }

    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private let lastGood: SdkConfigCache

    // All mutable state below is guarded by `lock`; `@unchecked Sendable` is
    // sound on that invariant.
    private let lock = NSLock()
    private var entry: Entry?
    private var inFlight: Task<PublicAppConfig, Error>?

    /// - Parameters:
    ///   - ttl: How long a fetched configuration is reused.
    ///   - now: Current time; injectable so tests can drive virtual time.
    ///   - lastGood: The on-disk failure fallback for this client's app key.
    init(
        ttl: TimeInterval = AppConfigStore.defaultTTL,
        now: @escaping @Sendable () -> Date = { Date() },
        lastGood: SdkConfigCache
    ) {
        self.ttl = ttl
        self.now = now
        self.lastGood = lastGood
    }

    /// The cached configuration while it is within the TTL window, `nil`
    /// otherwise. Synchronous so callers can resolve without a hop.
    func cachedConfig() -> PublicAppConfig? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry else { return nil }
        guard now().timeIntervalSince(entry.fetchedAt) < ttl else { return nil }
        return entry.config
    }

    /// Returns the configuration through the cache: the TTL entry when fresh,
    /// otherwise joining the single in-flight fetch or starting one.
    ///
    /// The fetch runs in an unstructured task, so a caller that is cancelled
    /// while waiting neither aborts the shared request nor strands its
    /// co-waiters — the completed response still warms the cache for the next
    /// presentation. `fetch` is only invoked by the caller that starts the
    /// request; co-waiters' closures are ignored.
    /// - Parameter fetch: The authoritative network read, normally
    ///   ``FeedbackClient/fetchAppConfig()``.
    func config(
        fetch: @escaping @Sendable () async throws -> PublicAppConfig
    ) async throws -> PublicAppConfig {
        if let cached = cachedConfig() { return cached }
        return try await awaitJoinedFetch(fetch)
    }

    /// Forces a network refresh, bypassing the TTL window.
    ///
    /// Joins an in-flight fetch when one is running (its result is fresh by
    /// construction — a fresh TTL entry never starts one), otherwise starts a
    /// new request and installs the result as the cached entry.
    /// - Parameter fetch: The authoritative network read, normally
    ///   ``FeedbackClient/fetchAppConfig()``.
    func forceRefresh(
        fetch: @escaping @Sendable () async throws -> PublicAppConfig
    ) async throws -> PublicAppConfig {
        try await awaitJoinedFetch(fetch)
    }

    /// The last successfully fetched appearance (disk-backed), for failure
    /// paths that must keep the last working configuration in force.
    func lastGoodAppearance() -> SdkAppearance? {
        lastGood.cachedAppearance()
    }

    // MARK: Lock-guarded sections (kept synchronous: `NSLock.unlock` is
    // unavailable from async contexts)

    /// Awaits the single in-flight fetch, starting it when the caller is the
    /// first reader. Only the reader that started the request records the
    /// outcome (TTL entry + last-good persistence).
    private func awaitJoinedFetch(
        _ fetch: @escaping @Sendable () async throws -> PublicAppConfig
    ) async throws -> PublicAppConfig {
        let (task, created) = joinOrCreateFetch(fetch)
        do {
            let config = try await task.value
            if created {
                finish(with: .success(config))
                lastGood.store(config.sdk)
            }
            return config
        } catch {
            if created { finish(with: .failure(error)) }
            throw error
        }
    }

    // MARK: Lock-guarded sections (kept synchronous: `NSLock.unlock` is
    // unavailable from async contexts)

    /// Returns the in-flight fetch to join, or — when the caller is the first
    /// reader — starts one and reports `created: true`.
    private func joinOrCreateFetch(
        _ fetch: @escaping @Sendable () async throws -> PublicAppConfig
    ) -> (task: Task<PublicAppConfig, Error>, created: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if let inFlight { return (inFlight, false) }
        let task = Task { try await fetch() }
        inFlight = task
        return (task, true)
    }

    /// Records the outcome of the fetch the caller started: installs the TTL
    /// entry on success, always releases the in-flight slot.
    private func finish(with result: Result<PublicAppConfig, Error>) {
        lock.lock()
        defer { lock.unlock() }
        inFlight = nil
        if case .success(let config) = result {
            entry = Entry(config: config, fetchedAt: now())
        }
    }
}
