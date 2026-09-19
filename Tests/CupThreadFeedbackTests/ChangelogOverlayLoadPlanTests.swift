import Foundation
import Testing
@testable import CupThreadFeedback

/// Regression coverage for issue #44: initializing ``ChangelogOverlayView``
/// with pre-fetched `entries` but no `appearance` used to skip the console
/// configuration entirely, silently rendering default copy and theme.
@Suite("ChangelogOverlayLoadPlanTests", .serialized)
struct ChangelogOverlayLoadPlanTests {
    static let apiHost = "changelog-loadplan.example.com"

    // MARK: - Plan truth table

    @Test func preparedEntriesAndAppearanceSkipConfigFetch() {
        let plan = ChangelogOverlayView.loadPlan(entries: [makeEntry()], appearance: .defaults)

        #expect(plan == .showPrepared(needsConfigFetch: false))
    }

    @Test func preparedEntriesWithoutAppearanceNeedsConfigFetch() {
        let plan = ChangelogOverlayView.loadPlan(entries: [makeEntry()], appearance: nil)

        #expect(plan == .showPrepared(needsConfigFetch: true))
    }

    @Test func noPreparedEntriesAlwaysFetchesRemote() {
        #expect(ChangelogOverlayView.loadPlan(entries: nil, appearance: nil) == .fetchRemote)
        #expect(ChangelogOverlayView.loadPlan(entries: nil, appearance: .defaults) == .fetchRemote)
    }

    // MARK: - Public init pairing

    @Test func preparedInitKeepsEntriesAndAppearancePaired() {
        let view = ChangelogOverlayView(
            client: makeClient(),
            prepared: (entries: [makeEntry()], appearance: makeConsoleAppearance())
        )

        #expect(view.preparedLoadPlan == .showPrepared(needsConfigFetch: false))
    }

    @Test func entriesOnlyInitStillNeedsConfigFetch() {
        let view = ChangelogOverlayView(client: makeClient(), entries: [makeEntry()])

        #expect(view.preparedLoadPlan == .showPrepared(needsConfigFetch: true))
    }

    @Test func nilPreparedResultFallsBackToSelfLoading() {
        let view = ChangelogOverlayView(client: makeClient(), prepared: nil)

        #expect(view.preparedLoadPlan == .fetchRemote)
    }

    // MARK: - Appearance fallback fetch (#44)

    @Test func fallbackAppearanceFetchesConsoleConfig() async throws {
        let requests = CaptureBox<[String]>()
        requests.value = []
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            requests.value?.append(request.url?.path ?? "")
            var payload = makeConfigJSON()
            payload["sdk"] = makeConsoleSDKJSON()
            return (makeHTTPResponse(), try encodeJSON(payload))
        }
        let client = Self.makeIsolatedClient(appKey: "app_loadplan_fetch")

        let appearance = await ChangelogOverlayView.resolveFallbackAppearance(in: client)

        #expect(appearance.changelogOverlay.title == "Release Radar")
        #expect(appearance.theme == .ocean)
        let configRequests = (requests.value ?? []).filter { $0.contains("/config/") }
        #expect(configRequests.count == 1)
    }

    @Test func fallbackAppearanceKeepsLastGoodAppearanceWhenFetchFails() async throws {
        let cache = SdkConfigCache(appKey: "app_loadplan_lastgood", storage: InMemoryConfigStorage())
        cache.store(makeConsoleAppearance())
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 500), try encodeJSON(["error": "boom"]))
        }
        let client = Self.makeIsolatedClient(appKey: "app_loadplan_lastgood", lastGood: cache)

        let appearance = await ChangelogOverlayView.resolveFallbackAppearance(in: client)

        #expect(appearance == makeConsoleAppearance())
    }

    @Test func fallbackAppearanceDefaultsWhenFetchFailsWithNoCache() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 404), try encodeJSON(["error": "App not found"]))
        }
        let client = Self.makeIsolatedClient(appKey: "app_loadplan_cold")

        let appearance = await ChangelogOverlayView.resolveFallbackAppearance(in: client)

        #expect(appearance == .defaults)
    }

    // MARK: - Helpers

    /// A client whose config store is fully isolated: unique in-memory
    /// last-good cache, so tests never read `UserDefaults` state written by
    /// other suites.
    static func makeIsolatedClient(appKey: String, lastGood: SdkConfigCache? = nil) -> FeedbackClient {
        makeClient(
            baseURL: URL(string: "https://\(apiHost)")!,
            appKey: appKey,
            configStore: AppConfigStore(lastGood: lastGood ?? SdkConfigCache(
                appKey: appKey,
                storage: InMemoryConfigStorage()
            ))
        )
    }

    private func makeEntry() -> ChangelogEntry {
        ChangelogEntry(
            id: "e_loadplan_1",
            title: "Version 1.0",
            body: "First release",
            versionLabel: "1.0.0",
            publishedAt: "2026-01-01T00:00:00.000Z",
            linkedRequests: []
        )
    }

    /// A console appearance distinct from ``SdkAppearance/defaults``.
    private func makeConsoleAppearance() -> SdkAppearance {
        SdkAppearance(
            theme: .ocean,
            changelogOverlay: ChangelogOverlayConfig(
                title: "Release Radar",
                subtitle: "Fresh builds",
                entryCount: 5,
                primaryButton: "Nice",
                closeButton: "Later"
            )
        )
    }

    private func makeConsoleSDKJSON() -> [String: Any] {
        [
            "theme": "ocean",
            "features": ["changelog": true],
            "changelogOverlay": [
                "title": "Release Radar",
                "subtitle": "Fresh builds",
                "entryCount": 5,
                "primaryButton": "Nice",
                "closeButton": "Later"
            ]
        ]
    }
}

/// In-memory ``SdkConfigCacheStorage`` so failure-path tests are independent
/// of the process-wide `UserDefaults`.
private final class InMemoryConfigStorage: SdkConfigCacheStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ data: Data, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = data
    }
}
