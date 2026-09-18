import Foundation
import Testing
@testable import CupThreadFeedback

// All tests share the static MockURLProtocol handler, so they run serialized.
// This suite uses its own base host so it can run in parallel with the other suites.
@Suite("AppConfigStore", .serialized)
@MainActor
struct AppConfigStoreTests {
    private static let host = "appconfig.example.com"

    private let suiteName: String
    private let defaults: UserDefaults

    init() {
        suiteName = "AppConfigStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    // MARK: - Helpers

    /// Thread-safe request counter installed in the mock handler.
    private final class RequestCounter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var configRequests = 0
        private(set) var changelogRequests = 0

        func record(path: String) {
            lock.lock()
            defer { lock.unlock() }
            if path.contains("/public/config/") {
                configRequests += 1
            } else if path.contains("/changelog") {
                changelogRequests += 1
            }
        }
    }

    /// Mutable clock so tests can drive TTL expiry without waiting.
    private final class MutableClock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: Date

        init() {
            time = Date(timeIntervalSince1970: 1_000_000)
        }

        func advance(by interval: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            time = time.addingTimeInterval(interval)
        }

        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return time
        }
    }

    private func makeCounter() -> RequestCounter {
        RequestCounter()
    }

    private func makeStore(
        appKey: String,
        clock: MutableClock? = nil,
        ttl: TimeInterval = AppConfigStore.defaultTTL
    ) -> AppConfigStore {
        AppConfigStore(
            ttl: ttl,
            now: { clock?.now() ?? Date() },
            lastGood: SdkConfigCache(appKey: appKey, storage: UserDefaultsConfigStorage(userDefaults: defaults))
        )
    }

    private func makeStoreClient(appKey: String, store: AppConfigStore) -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(Self.host)")!, appKey: appKey, configStore: store)
    }

    private func configJSON(appKey: String, theme: String = "ocean", featureRequests: Bool = false) throws -> Data {
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
        return try encodeJSON(payload)
    }

    private func setConfigHandler(appKey: String, counter: RequestCounter, theme: String = "ocean") throws {
        let payload = try configJSON(appKey: appKey, theme: theme)
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            counter.record(path: request.url?.path ?? "")
            return (makeHTTPResponse(), payload)
        }
    }

    private func setConfigThenChangelogHandler(
        appKey: String,
        counter: RequestCounter,
        theme: String = "ocean"
    ) throws {
        let configPayload = try configJSON(appKey: appKey, theme: theme)
        let changelogPayload = try encodeJSON([
            "entries": [[
                "id": "cl_1",
                "title": "Entry cl_1",
                "body": "Improvements and fixes.",
                "versionLabel": NSNull(),
                "publishedAt": "2026-09-01T00:00:00.000Z",
                "linkedRequests": [] as [[String: String]]
            ]],
            "hasMore": false,
            "nextCursor": NSNull()
        ] as [String: Any])
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            let path = request.url?.path ?? ""
            counter.record(path: path)
            if path.contains("/changelog") {
                return (makeHTTPResponse(), changelogPayload)
            }
            return (makeHTTPResponse(), configPayload)
        }
    }

    private func setFailureHandler(counter: RequestCounter) {
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            counter.record(path: request.url?.path ?? "")
            return (makeHTTPResponse(status: 500), Data("server unavailable".utf8))
        }
    }

    private func requireReady(_ status: SdkConfigStatus) throws -> SdkAppearance {
        guard case .ready(let appearance) = status else {
            Issue.record("Expected .ready, got \(status)")
            throw TestRequirementFailure()
        }
        return appearance
    }

    private struct TestRequirementFailure: Error {}

    // MARK: - Coalescing

    @Test func coalescesConcurrentReadsIntoOneRequest() async throws {
        let appKey = "app_coalesce"
        let counter = makeCounter()
        try setConfigHandler(appKey: appKey, counter: counter)
        let store = makeStore(appKey: appKey)
        let client = makeStoreClient(appKey: appKey, store: store)

        // Both tasks queue on the serial MainActor: the first runs to its
        // first suspension (the shared in-flight fetch is registered there),
        // so the second can only join it.
        let first = Task { try await client.cachedAppConfig() }
        let second = Task { try await client.cachedAppConfig() }
        let result1 = try await first.value
        let result2 = try await second.value

        #expect(counter.configRequests == 1, "Concurrent readers must share one in-flight request")
        #expect(result1 == result2)
    }

    // MARK: - TTL

    @Test func reusesCachedConfigWithinTTL() async throws {
        let appKey = "app_ttl_fresh"
        let counter = makeCounter()
        try setConfigHandler(appKey: appKey, counter: counter)
        let store = makeStore(appKey: appKey)
        let client = makeStoreClient(appKey: appKey, store: store)

        _ = try await client.cachedAppConfig()
        #expect(store.cachedConfig() != nil, "A successful fetch must populate the TTL entry")
        let second = try await client.cachedAppConfig()

        #expect(counter.configRequests == 1, "A read within the TTL window must not hit the network")
        #expect(second.name == "Demo App")
    }

    @Test func refetchesAfterTTLExpires() async throws {
        let appKey = "app_ttl_expire"
        let clock = MutableClock()
        let counter = makeCounter()
        try setConfigHandler(appKey: appKey, counter: counter, theme: "ocean")
        let store = makeStore(appKey: appKey, clock: clock)
        let client = makeStoreClient(appKey: appKey, store: store)

        let first = try await client.cachedAppConfig()
        #expect(first.sdk.theme == .ocean)

        try setConfigHandler(appKey: appKey, counter: counter, theme: "midnight")
        clock.advance(by: AppConfigStore.defaultTTL + 1)
        #expect(store.cachedConfig() == nil, "An expired entry must not be served")

        let second = try await client.cachedAppConfig()
        #expect(counter.configRequests == 2, "An expired entry must trigger exactly one refresh")
        #expect(second.sdk.theme == .midnight)
    }

    // MARK: - Failure handling

    @Test func failedFetchIsNotCachedAndRetryIssuesNewRequest() async throws {
        let appKey = "app_fail_retry"
        let counter = makeCounter()
        setFailureHandler(counter: counter)
        let store = makeStore(appKey: appKey)
        let client = makeStoreClient(appKey: appKey, store: store)

        do {
            _ = try await client.cachedAppConfig()
            Issue.record("Expected the cached read to throw on a 500")
        } catch {
            // Expected: the failure is surfaced, not swallowed.
        }
        #expect(store.cachedConfig() == nil, "A failed fetch must not populate the TTL entry")

        try setConfigHandler(appKey: appKey, counter: counter)
        let recovered = try await client.cachedAppConfig()
        #expect(counter.configRequests == 2, "A retry after failure must issue a fresh request")
        #expect(recovered.appKey == appKey)
    }

    @Test func successPersistsLastGoodAppearance() async throws {
        let appKey = "app_last_good"
        let counter = makeCounter()
        try setConfigHandler(appKey: appKey, counter: counter, theme: "forest")
        let store = makeStore(appKey: appKey)
        let client = makeStoreClient(appKey: appKey, store: store)

        let config = try await client.cachedAppConfig()
        let cached = SdkConfigCache(
            appKey: appKey,
            storage: UserDefaultsConfigStorage(userDefaults: defaults)
        ).cachedAppearance()

        #expect(cached == config.sdk, "A success must be written through to the last-good cache")
        #expect(store.lastGoodAppearance() == config.sdk)
    }

    @Test func failureAfterSuccessKeepsLastGoodAvailable() async throws {
        let appKey = "app_last_good_failure"
        let clock = MutableClock()
        let counter = makeCounter()
        try setConfigHandler(appKey: appKey, counter: counter, theme: "sunset")
        let store = makeStore(appKey: appKey, clock: clock)
        let client = makeStoreClient(appKey: appKey, store: store)

        let good = try await client.cachedAppConfig()

        setFailureHandler(counter: counter)
        clock.advance(by: AppConfigStore.defaultTTL + 1)
        do {
            _ = try await client.cachedAppConfig()
            Issue.record("Expected the expired refresh to throw on a 500")
        } catch {
            // Expected.
        }

        #expect(store.lastGoodAppearance() == good.sdk, "A failed refresh must keep the last-good appearance")
    }

    // MARK: - Loader integration

    @Test func warmStoreResolvesLoaderSynchronouslyWithoutFetching() async throws {
        // Re-presentation contract: a loader created while the client's cache
        // is fresh starts .ready at init, so the surface gate resolves on the
        // first body evaluation and no new request is fired.
        let appKey = "app_warm_loader"
        let counter = makeCounter()
        try setConfigHandler(appKey: appKey, counter: counter, theme: "midnight")
        let store = makeStore(appKey: appKey)
        let client = makeStoreClient(appKey: appKey, store: store)

        _ = try await client.cachedAppConfig()
        #expect(counter.configRequests == 1)

        let rePresented = SdkConfigLoader(client: client, store: store)
        let appearance = try requireReady(rePresented.status)
        #expect(appearance.theme == .midnight)
        #expect(counter.configRequests == 1, "A warm loader init must not fetch")
    }

    // MARK: - Cache scope

    @Test func cacheIsScopedPerClientInstance() async throws {
        let appKey = "app_scope"
        let counter = makeCounter()
        try setConfigHandler(appKey: appKey, counter: counter)

        let clientA = makeStoreClient(appKey: appKey, store: makeStore(appKey: appKey))
        let clientB = makeStoreClient(appKey: appKey, store: makeStore(appKey: appKey))

        _ = try await clientA.cachedAppConfig()
        _ = try await clientB.cachedAppConfig()

        #expect(counter.configRequests == 2, "Each client instance owns its own store")
    }

    @Test func fetchAppConfigBypassesTheCache() async throws {
        let appKey = "app_bypass"
        let counter = makeCounter()
        try setConfigHandler(appKey: appKey, counter: counter)
        let store = makeStore(appKey: appKey)
        let client = makeStoreClient(appKey: appKey, store: store)

        // The authoritative read never consults or stores in the TTL entry…
        _ = try await client.fetchAppConfig()
        _ = try await client.fetchAppConfig()
        #expect(counter.configRequests == 2)
        #expect(store.cachedConfig() == nil)

        // …while the cached read performs exactly one request of its own.
        _ = try await client.cachedAppConfig()
        let again = try await client.cachedAppConfig()
        #expect(counter.configRequests == 3)
        #expect(again.appKey == appKey)
    }

    // MARK: - Changelog overlay paths

    @Test func overlaySelfLoadedPathReusesCachedConfig() async throws {
        let appKey = "app_overlay_self"
        let counter = makeCounter()
        try setConfigThenChangelogHandler(appKey: appKey, counter: counter)
        let store = makeStore(appKey: appKey)
        let client = makeStoreClient(appKey: appKey, store: store)

        let first = await ChangelogOverlayView.fetchSelfLoadedContent(in: client)
        let second = await ChangelogOverlayView.fetchSelfLoadedContent(in: client)

        #expect(counter.configRequests == 1, "Two overlay presentations must cost one config GET")
        #expect(counter.changelogRequests == 2)
        guard case .entries(let entries, let appearance) = first else {
            Issue.record("Expected entries, got \(first)")
            return
        }
        #expect(entries.count == 1)
        #expect(appearance.theme == .ocean)
        guard case .entries = second else {
            Issue.record("Expected entries on the second pass, got \(second)")
            return
        }
    }

    @Test func prepareChangelogOverlaySharesTheConfigCache() async throws {
        let appKey = "app_overlay_prepare"
        let counter = makeCounter()
        try setConfigThenChangelogHandler(appKey: appKey, counter: counter)
        let store = makeStore(appKey: appKey)
        let client = makeStoreClient(appKey: appKey, store: store)

        let prepared = try await client.prepareChangelogOverlay(onlyIfUnseen: false)
        let config = try await client.cachedAppConfig()

        #expect(counter.configRequests == 1, "The prepare path must warm the cache for later readers")
        #expect(config.appKey == appKey)
        #expect(prepared?.entries.count == 1)
        #expect(prepared?.appearance.theme == .ocean)
    }
}
