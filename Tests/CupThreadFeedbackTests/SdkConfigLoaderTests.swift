import Foundation
import Testing
@testable import CupThreadFeedback

// All tests share the static MockURLProtocol handler, so they run serialized.
// This suite uses its own base host so it can run in parallel with the other suites.
@Suite("SdkConfigLoader", .serialized)
@MainActor
struct SdkConfigLoaderTests {
    private static let host = "sdkconfig.example.com"

    private let suiteName: String
    private let defaults: UserDefaults

    init() {
        suiteName = "SdkConfigLoaderTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    // MARK: - Helpers

    private func buildClient(appKey: String, store: AppConfigStore? = nil) -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(Self.host)")!, appKey: appKey, configStore: store)
    }

    private func makeStore(appKey: String, ttl: TimeInterval = AppConfigStore.defaultTTL) -> AppConfigStore {
        AppConfigStore(
            ttl: ttl,
            lastGood: SdkConfigCache(appKey: appKey, storage: UserDefaultsConfigStorage(userDefaults: defaults))
        )
    }

    private func makeCache(appKey: String) -> SdkConfigCache {
        SdkConfigCache(appKey: appKey, storage: UserDefaultsConfigStorage(userDefaults: defaults))
    }

    private func makeLoader(appKey: String, ttl: TimeInterval = AppConfigStore.defaultTTL) -> SdkConfigLoader {
        let store = makeStore(appKey: appKey, ttl: ttl)
        return SdkConfigLoader(client: buildClient(appKey: appKey, store: store), store: store)
    }

    private func configJSON(appKey: String, featureRequests: Bool = false, theme: String = "ocean") -> [String: Any] {
        var payload = makeConfigJSON()
        payload["appKey"] = appKey
        payload["sdk"] = [
            "theme": theme,
            "features": [
                "feedback": true,
                "featureRequests": featureRequests,
                "roadmap": true,
                "changelog": true
            ]
        ]
        return payload
    }

    private func setSuccessHandler(appKey: String, featureRequests: Bool = false) throws {
        // Encode outside the handler closure: the handler runs off MainActor.
        let payload = try encodeJSON(configJSON(appKey: appKey, featureRequests: featureRequests))
        MockURLProtocol.setHandler(forHost: Self.host) { _ in
            (makeHTTPResponse(), payload)
        }
    }

    private func setFailureHandler() {
        MockURLProtocol.setHandler(forHost: Self.host) { _ in
            (makeHTTPResponse(status: 500), Data("server unavailable".utf8))
        }
    }

    private func setNotFoundHandler() {
        // #129: a private app answers the config endpoint with the same 404
        // body as an unknown app key.
        MockURLProtocol.setHandler(forHost: Self.host) { _ in
            (makeHTTPResponse(status: 404), Data(#"{"error": "App not found"}"#.utf8))
        }
    }

    private func requireReady(_ status: SdkConfigStatus) throws -> SdkAppearance {
        guard case .ready(let appearance) = status else {
            Issue.record("Expected .ready, got \(status)")
            throw TestRequirementFailure()
        }
        return appearance
    }

    private func requireFailed(_ status: SdkConfigStatus) throws -> (appearance: SdkAppearance?, error: any Error) {
        guard case .failed(let appearance, let error) = status else {
            Issue.record("Expected .failed, got \(status)")
            throw TestRequirementFailure()
        }
        return (appearance, error)
    }

    private struct TestRequirementFailure: Error {}

    // MARK: - Load outcomes

    @Test func initialStatusIsLoading() {
        let loader = makeLoader(appKey: "app_status_initial")
        guard case .loading = loader.status else {
            Issue.record("A fresh loader must start as .loading, got \(loader.status)")
            return
        }
    }

    @Test func successfulLoadPublishesReadyAndPersistsCache() async throws {
        try setSuccessHandler(appKey: "app_cache_success", featureRequests: false)

        let loader = makeLoader(appKey: "app_cache_success")
        await loader.load()

        let appearance = try requireReady(loader.status)
        #expect(appearance.theme == .ocean)
        #expect(appearance.features.featureRequests == false)
        #expect(appearance.features.feedback == true)
        let appConfig = try #require(loader.config)
        #expect(appConfig.appKey == "app_cache_success")
        #expect(appConfig.allowAnonymousVote == false)

        // The last-good cache received the same appearance for this app key.
        #expect(makeCache(appKey: "app_cache_success").cachedAppearance() == appearance)
    }

    @Test func failureWithoutCacheFailsClosed() async throws {
        // Regression for #61: a failed fetch with no cache must NOT fall back
        // to .defaults (which enables every feature).
        setFailureHandler()

        let loader = makeLoader(appKey: "app_fail_closed")
        await loader.load()

        let failure = try requireFailed(loader.status)
        #expect(failure.appearance == nil, "A failed fetch with no cache must resolve to no appearance, not .defaults")
        #expect(failure.error is FeedbackClientError, "The fetch error must be propagated to observers")
    }

    @Test func failureAfterSuccessKeepsLastGoodConfig() async throws {
        try setSuccessHandler(appKey: "app_keep_good", featureRequests: false)

        // ttl: 0 makes every load hit the network, matching the pre-cache
        // loader semantics this regression guards.
        let loader = makeLoader(appKey: "app_keep_good", ttl: 0)
        await loader.load()
        let good = try requireReady(loader.status)

        setFailureHandler()
        await loader.load()

        let failure = try requireFailed(loader.status)
        #expect(failure.appearance == good, "A later failure must keep the last successful feature flags")
    }

    @Test func appMadePrivate404KeepsLastGoodConfig() async throws {
        // Regression for #129: an app switched to private answers the config
        // endpoint with 404 ("App not found"). The loader must fail closed
        // and keep the last-good appearance instead of ever resolving .ready.
        try setSuccessHandler(appKey: "app_private_404", featureRequests: false)

        let loader = makeLoader(appKey: "app_private_404", ttl: 0)
        await loader.load()
        let good = try requireReady(loader.status)

        setNotFoundHandler()
        await loader.load()

        let failure = try requireFailed(loader.status)
        #expect(failure.appearance == good, "A private app's 404 must keep the last-good config")
        guard case .unexpectedStatus(let code, let message, _) = failure.error as? FeedbackClientError else {
            Issue.record("Expected .unexpectedStatus, got \(failure.error)")
            return
        }
        #expect(code == 404)
        #expect(message == "App not found")
    }

    @Test func firstLoadAgainstPrivateApp404FailsClosed() async throws {
        // #129: an app key that is private (or unknown) answers the config
        // endpoint with 404; a fresh install must resolve to no appearance,
        // never .defaults.
        setNotFoundHandler()

        let loader = makeLoader(appKey: "app_private_first_load")
        await loader.load()

        let failure = try requireFailed(loader.status)
        #expect(failure.appearance == nil, "A 404 config fetch with no cache must resolve to no appearance")
        #expect(failure.error is FeedbackClientError, "The fetch error must be propagated to observers")
    }

    @Test func relaunchRestoresCachedConfigOnFailure() async throws {
        // Simulates an app relaunch: a fresh loader + a fresh client, backed by
        // the same persistent defaults, after the first run succeeded.
        try setSuccessHandler(appKey: "app_relaunch", featureRequests: false)

        let firstRun = makeLoader(appKey: "app_relaunch")
        await firstRun.load()
        let good = try requireReady(firstRun.status)

        setFailureHandler()
        let nextRun = makeLoader(appKey: "app_relaunch")
        await nextRun.load()

        let failure = try requireFailed(nextRun.status)
        #expect(failure.appearance == good, "A new loader instance must restore the persisted last-good config")
    }

    @Test func cacheIsIsolatedPerAppKey() async throws {
        try setSuccessHandler(appKey: "app_isolated_a", featureRequests: false)

        let loaderA = makeLoader(appKey: "app_isolated_a")
        await loaderA.load()
        _ = try requireReady(loaderA.status)

        setFailureHandler()
        let loaderB = makeLoader(appKey: "app_isolated_b")
        await loaderB.load()

        let failure = try requireFailed(loaderB.status)
        #expect(failure.appearance == nil, "Another app key's cached config must not leak across apps")
        #expect(makeCache(appKey: "app_isolated_b").cachedAppearance() == nil)
    }

    @Test func retryAfterFailureSucceeds() async throws {
        setFailureHandler()

        let loader = makeLoader(appKey: "app_retry")
        await loader.load()
        _ = try requireFailed(loader.status)

        try setSuccessHandler(appKey: "app_retry", featureRequests: true)
        await loader.load()

        let appearance = try requireReady(loader.status)
        #expect(appearance.features.featureRequests == true)
    }

    @Test func cancellationKeepsPriorStatus() async throws {
        try setSuccessHandler(appKey: "app_cancelled")

        let loader = makeLoader(appKey: "app_cancelled")
        let task = Task { await loader.load() }
        task.cancel()
        await task.value

        switch loader.status {
        case .failed:
            Issue.record("A cancelled load must not be reported as a failure: \(loader.status)")
        case .loading, .ready:
            break
        }
    }

    @Test func loadWithinTTLServesCachedConfigWithoutFetching() async throws {
        // #28: a load while the client's short-TTL cache is fresh resolves
        // from the shared cache — the network is never consulted, so even a
        // failing endpoint cannot regress the resolved state.
        try setSuccessHandler(appKey: "app_load_cached", featureRequests: false)

        let loader = makeLoader(appKey: "app_load_cached")
        await loader.load()
        let good = try requireReady(loader.status)

        setFailureHandler()
        await loader.load()

        let stillReady = try requireReady(loader.status)
        #expect(stillReady == good, "A cached load must keep the fetched appearance")
    }

    @Test func refreshBypassesTheSharedCache() async throws {
        // #28: the host-initiated forced refresh always hits the network,
        // even while the shared cache is still fresh.
        try setSuccessHandler(appKey: "app_refresh", featureRequests: false)

        let loader = makeLoader(appKey: "app_refresh")
        await loader.load()
        let stale = try requireReady(loader.status)
        #expect(stale.features.featureRequests == false)

        try setSuccessHandler(appKey: "app_refresh", featureRequests: true)
        await loader.refresh()

        let appearance = try requireReady(loader.status)
        #expect(appearance.features.featureRequests == true, "refresh() must refetch within the TTL window")
    }
}

// MARK: - Surface resolution

@Suite("SdkSurfaceResolution")
struct SdkSurfaceResolutionTests {
    private let cachedAppearance = SdkAppearance(
        theme: .midnight,
        features: SdkFeatures(feedback: true, featureRequests: false, roadmap: true, changelog: false),
        changelogOverlay: .defaults
    )
    private let remoteAppearance = SdkAppearance(
        theme: .ocean,
        features: SdkFeatures(feedback: false, featureRequests: true, roadmap: true, changelog: true),
        changelogOverlay: .defaults
    )

    private func failed(_ appearance: SdkAppearance?) -> SdkConfigStatus {
        .failed(appearance: appearance, error: FeedbackClientError.invalidResponse)
    }

    @Test func missingStatusesWait() {
        #expect(sdkSurfaceResolution(injected: nil, local: nil) == .waiting)
    }

    @Test func firstLoadWaits() {
        #expect(sdkSurfaceResolution(injected: nil, local: .loading) == .waiting)
    }

    @Test func readyStatusResolvesAppearance() {
        let resolution = sdkSurfaceResolution(injected: nil, local: .ready(remoteAppearance))
        #expect(resolution == .resolved(remoteAppearance))
    }

    @Test func failureWithCacheResolvesCache() {
        let resolution = sdkSurfaceResolution(injected: nil, local: failed(cachedAppearance))
        #expect(resolution == .resolved(cachedAppearance))
    }

    @Test func failureWithoutCacheIsUnavailable() {
        // The #61 regression: .failed(nil) must not resolve to defaults or
        // enable every feature.
        let resolution = sdkSurfaceResolution(injected: nil, local: failed(nil))
        #expect(resolution == .unavailable)
    }

    @Test func injectedStatusWinsOverLocalLoader() {
        #expect(sdkSurfaceResolution(injected: .ready(remoteAppearance), local: .loading) == .resolved(remoteAppearance))
        #expect(sdkSurfaceResolution(injected: failed(cachedAppearance), local: .ready(remoteAppearance)) == .resolved(cachedAppearance))
        #expect(sdkSurfaceResolution(injected: failed(nil), local: .ready(remoteAppearance)) == .unavailable)
    }
}
