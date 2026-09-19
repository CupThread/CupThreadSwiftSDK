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

// MARK: - Loader

/// Observable loader for the remote console configuration
/// (`GET /api/v1/public/config/{appKey}`).
///
/// Reads go through the client's shared short-TTL app-config cache: loaders
/// on the same client coalesce into a single in-flight request, and a read
/// within the TTL window reuses the last response instead of re-fetching.
/// ``CupThreadTheme`` owns one loader by default. Create your own and pass it
/// to the theme when you also want to observe the load state or trigger a
/// retry from host code:
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
/// await config.load()    // retry after a failure (failures are never cached)
/// await config.refresh() // force a refetch, bypassing the short-TTL cache
/// ```
///
/// Fetch results are applied only on success or via the last-good cache; see
/// ``SdkConfigStatus`` for the exact semantics. A loader created while the
/// client's cache is still within its TTL window starts as
/// ``SdkConfigStatus/ready(_:)`` immediately, so re-presented surfaces gate on
/// console state from their first body evaluation.
@MainActor
public final class SdkConfigLoader: ObservableObject {
    /// The current load state.
    ///
    /// Starts as ``SdkConfigStatus/loading`` (unless the shared cache already
    /// holds a fresh configuration) and never resets: a refresh keeps the
    /// previously resolved state visible until the new result arrives, so
    /// surfaces never flash back to a placeholder between fetches.
    @Published public private(set) var status: SdkConfigStatus = .loading

    /// The full public configuration from the last successful fetch, or `nil`
    /// when no fetch has succeeded in this session.
    ///
    /// SDK surfaces read the permission switches
    /// (``PublicAppConfig/allowsAnonymousVote`` and friends) from here for UX
    /// preflight gating. The on-disk last-good cache stores appearance only,
    /// so a failed refresh that falls back to that cache leaves this `nil` —
    /// surfaces then fail open and rely on the server's semantic 401/403
    /// responses, because client permission gating is a preflight, not
    /// access control.
    @Published public private(set) var config: PublicAppConfig?

    private let client: FeedbackClient
    private let store: AppConfigStore

    /// Creates a loader for the given client.
    /// - Parameter client: The shared client; its app config store scopes the
    ///   TTL cache and the last-good fallback.
    public convenience init(client: FeedbackClient) {
        self.init(client: client, store: client.configStore)
    }

    init(client: FeedbackClient, store: AppConfigStore) {
        self.client = client
        self.store = store
        // A synchronous TTL hit resolves the gate before the first body
        // evaluation — no waiting placeholder on a warm cache.
        if let cached = store.cachedConfig() {
            config = cached
            status = .ready(cached.sdk)
        }
    }

    /// Resolves the console configuration once.
    ///
    /// A fresh cached value resolves immediately; otherwise the read joins or
    /// starts a single shared fetch. On success the appearance is published
    /// via ``SdkConfigStatus/ready(_:)`` and persisted to the last-good cache.
    /// On failure the cached appearance (if any) is published via
    /// ``SdkConfigStatus/failed(appearance:error:)``. Cancellation leaves the
    /// current status untouched.
    ///
    /// Because reads share the client's short-TTL cache, a call while the
    /// cached configuration is still fresh resolves from that cache without a
    /// network round trip; use ``SdkConfigLoader/refresh()`` when the read
    /// must bypass the cache.
    public func load() async {
        let client = self.client
        do {
            let appConfig = try await store.config { try await client.fetchAppConfig() }
            config = appConfig
            status = .ready(appConfig.sdk)
        } catch is CancellationError {
            // The surrounding task was cancelled (e.g. the view disappeared);
            // keep whatever was resolved before.
        } catch let error as URLError where error.code == .cancelled {
            // URLSession also surfaces task cancellation as URLError.
        } catch {
            status = .failed(appearance: store.lastGoodAppearance(), error: error)
        }
    }

    /// Forces a network refresh of the console configuration, bypassing the
    /// shared TTL cache.
    ///
    /// Same semantics as ``SdkConfigLoader/load()`` (success publishes
    /// ``SdkConfigStatus/ready(_:)`` and persists the last-good copy; failure
    /// publishes ``SdkConfigStatus/failed(appearance:error:)``), except that
    /// the fetch always runs and the new value replaces the cached entry.
    public func refresh() async {
        let client = self.client
        do {
            let appConfig = try await store.forceRefresh { try await client.fetchAppConfig() }
            config = appConfig
            status = .ready(appConfig.sdk)
        } catch is CancellationError {
            // The surrounding task was cancelled; keep whatever was resolved.
        } catch let error as URLError where error.code == .cancelled {
            // URLSession also surfaces task cancellation as URLError.
        } catch {
            status = .failed(appearance: store.lastGoodAppearance(), error: error)
        }
    }
}
