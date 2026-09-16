import Combine
import Foundation
import SwiftUI

// MARK: - Load status

/// Load state of the remote console configuration
/// (`GET /api/v1/public/config/{appKey}`), published by ``SdkConfigLoader``.
///
/// Configuration is only ever taken from ``SdkConfigStatus/ready(_:)`` or from
/// the cached appearance carried by a failure. A fetch that fails with no
/// cached value resolves to *no* configuration, which leaves feature-gated
/// surfaces unavailable (fail closed) until a retry succeeds — console
/// kill-switches never fail open, and a transport failure is never mistaken
/// for "the server enables everything".
public enum SdkConfigStatus: @unchecked Sendable {
    /// The first fetch is in flight and no configuration has been resolved yet.
    case loading
    /// The fetch succeeded; the appearance carries the console's theme,
    /// feature flags, and overlay copy.
    case ready(SdkAppearance)
    /// The fetch failed. `appearance` is the last successfully fetched
    /// configuration for this app key (restored from the on-disk cache), or
    /// `nil` when none exists. The SDK keeps applying `appearance` when
    /// present, so a later outage never rolls back to defaults.
    case failed(appearance: SdkAppearance?, error: any Error)
}

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

// MARK: - Loader

/// Observable loader for the remote console configuration
/// (`GET /api/v1/public/config/{appKey}`).
///
/// ``CupThreadTheme`` owns one by default. Create your own and pass it to the
/// theme when you also want to observe the load state or trigger a retry from
/// host code:
///
/// ```swift
/// @StateObject private var config = SdkConfigLoader(client: client)
///
/// CupThreadTheme(client: client, configLoader: config) {
///     NavigationStack { … }
/// }
///
/// // Elsewhere:
/// if case .failed(nil, let error) = await config.status {
///     // No cached configuration exists; surfaces are unavailable until a
///     // retry succeeds.
/// }
/// await config.load() // retry
/// ```
///
/// Fetch results are applied only on success or via the last-good cache; see
/// ``SdkConfigStatus`` for the exact semantics.
@MainActor
public final class SdkConfigLoader: ObservableObject {
    /// The current load state.
    ///
    /// Starts as ``SdkConfigStatus/loading`` and never resets: a refresh keeps
    /// the previously resolved state visible until the new result arrives, so
    /// surfaces never flash back to a placeholder between fetches.
    @Published public private(set) var status: SdkConfigStatus = .loading

    private let client: FeedbackClient
    private let cache: SdkConfigCache

    /// Creates a loader for the given client.
    /// - Parameter client: The shared client; its app key scopes the
    ///   last-good cache.
    public convenience init(client: FeedbackClient) {
        self.init(client: client, cache: SdkConfigCache(appKey: client.configuration.appKey))
    }

    init(client: FeedbackClient, cache: SdkConfigCache) {
        self.client = client
        self.cache = cache
    }

    /// Fetches the console configuration once.
    ///
    /// On success the appearance is published via ``SdkConfigStatus/ready(_:)``
    /// and persisted to the last-good cache. On failure the cached appearance
    /// (if any) is published via ``SdkConfigStatus/failed(appearance:error:)``.
    /// Cancellation leaves the current status untouched. Call again to retry.
    public func load() async {
        do {
            let appearance = try await client.fetchAppConfig().sdk
            cache.store(appearance)
            status = .ready(appearance)
        } catch is CancellationError {
            // The surrounding task was cancelled (e.g. the view disappeared);
            // keep whatever was resolved before.
        } catch let error as URLError where error.code == .cancelled {
            // URLSession also surfaces task cancellation as URLError.
        } catch {
            status = .failed(appearance: cache.cachedAppearance(), error: error)
        }
    }
}
