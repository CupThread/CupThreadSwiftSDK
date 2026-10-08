import Foundation
import Testing
@testable import CupThreadFeedback

@Suite("ChangelogOverlayPresentationTests", .serialized)
struct ChangelogOverlayPresentationTests {
    static let apiHost = "changelog-presentation.example.com"

    static func makeChangelogClient(
        overlayPresenter: (any ChangelogOverlayPresenter)? = nil
    ) -> FeedbackClient {
        makeClient(
            baseURL: URL(string: "https://\(apiHost)")!,
            overlayPresenter: overlayPresenter
        )
    }

    /// Mocks the config + changelog endpoints and records every request path.
    @discardableResult
    private func mockChangelogAPI(
        changelogEnabled: Bool = true,
        allowAnonymousChangelog: Bool = true,
        entries: [[String: Any]] = [makeDefaultEntry()]
    ) -> CaptureBox<[String]> {
        var payload = makeConfigJSON()
        payload["allowAnonymousChangelog"] = allowAnonymousChangelog
        payload["sdk"] = [
            "theme": "system",
            "features": ["changelog": changelogEnabled],
            "changelogOverlay": [
                "title": "What's New",
                "subtitle": "Latest updates",
                "entryCount": 3,
                "primaryButton": "Continue",
                "closeButton": "Close"
            ]
        ]
        let recordedPaths = CaptureBox<[String]>()
        recordedPaths.value = []
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            let path = request.url?.path ?? ""
            recordedPaths.value?.append(path)
            if path.contains("/changelog") {
                return (makeHTTPResponse(), try encodeJSON(["entries": entries]))
            }
            return (makeHTTPResponse(), try encodeJSON(payload))
        }
        return recordedPaths
    }

    private func mockChangelogAPIWithRequests(
        changelogEnabled: Bool = true,
        allowAnonymousChangelog: Bool = true,
        entryCount: Int = 3,
        changelogHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? = nil
    ) -> (client: FeedbackClient, requests: CaptureBox<[URLRequest]>) {
        var payload = makeConfigJSON()
        payload["allowAnonymousChangelog"] = allowAnonymousChangelog
        payload["sdk"] = [
            "theme": "system",
            "features": ["changelog": changelogEnabled],
            "changelogOverlay": [
                "title": "What's New",
                "subtitle": "Latest updates",
                "entryCount": entryCount,
                "primaryButton": "Continue",
                "closeButton": "Close"
            ]
        ]
        let recordedRequests = CaptureBox<[URLRequest]>()
        recordedRequests.value = []
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            recordedRequests.value?.append(request)
            let path = request.url?.path ?? ""
            if path.contains("/changelog") {
                if let changelogHandler {
                    return try changelogHandler(request)
                }
                return (makeHTTPResponse(), try encodeJSON(["entries": [makeDefaultEntry()]]))
            }
            return (makeHTTPResponse(), try encodeJSON(payload))
        }
        return (Self.makeChangelogClient(), recordedRequests)
    }

    @Test func refusedPresentationReturnsFalse() async throws {
        mockChangelogAPI()
        let stub = await RefusedStubPresenter()
        let client = Self.makeChangelogClient(overlayPresenter: stub)

        let result = try await withTimeout(seconds: 2) {
            try await client.presentLatestChangelog()
        }

        #expect(result == false)
    }

    @Test func successfulPresentationReturnsTrue() async throws {
        mockChangelogAPI()
        let stub = await SuccessfulStubPresenter()
        let client = Self.makeChangelogClient(overlayPresenter: stub)

        let result = try await withTimeout(seconds: 2) {
            try await client.presentLatestChangelog()
        }

        #expect(result == true)
    }

    @Test func watchdogFiresOnSilentFailure() async throws {
        let stub = await SilentFailureStubPresenter()
        let client = Self.makeChangelogClient(overlayPresenter: stub)
        let entries = [
            ChangelogEntry(
                id: "e1",
                title: "Update",
                body: "Notes",
                versionLabel: "1.0",
                publishedAt: "2026-01-01T00:00:00.000Z",
                linkedRequests: []
            )
        ]
        let appearance = SdkAppearance.defaults

        let startTime = ContinuousClock.now
        let result = try await withTimeout(seconds: 2) {
            await presentPreparedChangelogOverlay(
                client: client,
                entries: entries,
                appearance: appearance,
                presenter: stub,
                watchdogTimeout: .milliseconds(50)
            )
        }
        let elapsed = ContinuousClock.now - startTime

        #expect(result == false)
        #expect(elapsed < .seconds(1))
    }

    @Test func watchdogCancelledWhenPresented() async throws {
        let stub = await DelayedDismissStubPresenter()
        let client = Self.makeChangelogClient(overlayPresenter: stub)
        let entries = [
            ChangelogEntry(
                id: "e1",
                title: "Update",
                body: "Notes",
                versionLabel: "1.0",
                publishedAt: "2026-01-01T00:00:00.000Z",
                linkedRequests: []
            )
        ]
        let appearance = SdkAppearance.defaults

        let result = try await withTimeout(seconds: 2) {
            await presentPreparedChangelogOverlay(
                client: client,
                entries: entries,
                appearance: appearance,
                presenter: stub,
                watchdogTimeout: .milliseconds(50)
            )
        }

        #expect(result == true)
    }

    @Test func resumeBoxDoubleResumeIsNoOp() async {
        _ = await withCheckedContinuation { continuation in
            let box = ResumeBox(continuation)
            let first = box.finish(true)
            let second = box.finish(false)
            let third = box.finish(true)
            #expect(first == true)
            #expect(second == false)
            #expect(third == false)
        }
    }

    @Test @MainActor func hiddenChangelogReturnsFalseWithoutPresenting() async throws {
        mockChangelogAPI(changelogEnabled: false)
        let stub = SuccessfulStubPresenter()
        let client = Self.makeChangelogClient(overlayPresenter: stub)

        let result = try await client.presentLatestChangelog()
        #expect(result == false)
        #expect(stub.hasPresented == false)
    }

    // MARK: - Self-loading overlay feature gate (#38)

    @Test func sdkFeaturesIsEnabledMapsEverySurfaceSwitch() {
        let allOff = SdkFeatures(feedback: false, featureRequests: false, roadmap: false, changelog: false)
        #expect(!allOff.isEnabled(.feedback))
        #expect(!allOff.isEnabled(.featureRequests))
        #expect(!allOff.isEnabled(.roadmap))
        #expect(!allOff.isEnabled(.changelog))

        let allOn = SdkFeatures.allEnabled
        #expect(allOn.isEnabled(.feedback))
        #expect(allOn.isEnabled(.featureRequests))
        #expect(allOn.isEnabled(.roadmap))
        #expect(allOn.isEnabled(.changelog))
    }

    @Test func selfLoadedOverlaySkipsChangelogFetchWhenFeatureDisabled() async throws {
        let requests = mockChangelogAPI(changelogEnabled: false)
        let client = Self.makeChangelogClient()

        let content = await ChangelogOverlayView.fetchSelfLoadedContent(in: client)

        guard case .featureDisabled(let appearance)? = content else {
            Issue.record("Expected .featureDisabled, got \(String(describing: content))")
            return
        }
        // The console appearance is still applied so the sheet chrome (title,
        // buttons, tint) keeps matching the console even when disabled.
        #expect(appearance.changelogOverlay.title == "What's New")
        let paths = requests.value ?? []
        #expect(paths.contains { $0.contains("/config/") })
        #expect(!paths.contains { $0.contains("/changelog") })
    }

    @Test func selfLoadedOverlayFetchesEntriesWhenFeatureEnabled() async throws {
        let requests = mockChangelogAPI(changelogEnabled: true)
        let client = Self.makeChangelogClient()

        let content = await ChangelogOverlayView.fetchSelfLoadedContent(in: client)

        guard case .entries(let loaded, let appearance)? = content else {
            Issue.record("Expected .entries, got \(String(describing: content))")
            return
        }
        #expect(loaded.map(\.id) == ["e_presentation_1"])
        #expect(appearance.changelogOverlay.title == "What's New")
        let paths = requests.value ?? []
        #expect(paths.contains { $0.contains("/config/") })
        #expect(paths.contains { $0.contains("/changelog") })
    }

    @Test func selfLoadedOverlaySkipsChangelogFetchWhenAnonymousChangelogDisabled() async throws {
        let requests = mockChangelogAPI(changelogEnabled: true, allowAnonymousChangelog: false)
        let client = Self.makeChangelogClient()

        let content = await ChangelogOverlayView.fetchSelfLoadedContent(in: client)

        guard case .permissionDenied(let appearance)? = content else {
            Issue.record("Expected .permissionDenied, got \(String(describing: content))")
            return
        }
        #expect(appearance.changelogOverlay.title == "What's New")
        let paths = requests.value ?? []
        #expect(paths.contains { $0.contains("/config/") })
        #expect(!paths.contains { $0.contains("/changelog") })
    }

    @Test func selfLoadedOverlayFeatureDisabledWinsOverPermissionDenied() async throws {
        let requests = mockChangelogAPI(changelogEnabled: false, allowAnonymousChangelog: false)
        let client = Self.makeChangelogClient()

        let content = await ChangelogOverlayView.fetchSelfLoadedContent(in: client)

        guard case .featureDisabled(let appearance)? = content else {
            Issue.record("Expected .featureDisabled, got \(String(describing: content))")
            return
        }
        #expect(appearance.changelogOverlay.title == "What's New")
        let paths = requests.value ?? []
        #expect(paths.contains { $0.contains("/config/") })
        #expect(!paths.contains { $0.contains("/changelog") })
    }

    @Test func prepareChangelogOverlayReturnsNilWhenAnonymousChangelogDisabled() async throws {
        let requests = mockChangelogAPI(changelogEnabled: true, allowAnonymousChangelog: false)
        let client = Self.makeChangelogClient()

        let result = try await client.prepareChangelogOverlay()
        #expect(result == nil)
        let paths = requests.value ?? []
        #expect(paths.contains { $0.contains("/config/") })
        #expect(!paths.contains { $0.contains("/changelog") })
    }

    // MARK: - Single-page launch-path fetch (PERF-4)

    @Test func prepareChangelogOverlayRequestsSinglePageWithConfiguredEntryCountLimit() async throws {
        let (client, recorded) = mockChangelogAPIWithRequests(entryCount: 3)
        let prepared = try await client.prepareChangelogOverlay(onlyIfUnseen: false)

        #expect(prepared != nil)
        #expect(prepared?.entries.map(\.id) == ["e_presentation_1"])
        #expect(prepared?.appearance.changelogOverlay.entryCount == 3)

        let changelogRequests = (recorded.value ?? []).filter { $0.url?.path.contains("/changelog") == true }
        #expect(changelogRequests.count == 1)
        let first = try #require(changelogRequests.first)
        let query = queryItems(of: first)
        #expect(query["limit"] == "3")
        #expect(query["cursor"] == nil)
    }

    @Test func prepareChangelogOverlayWithCustomCapSizesLimitQuery() async throws {
        let (client, recorded) = mockChangelogAPIWithRequests(entryCount: 10)
        let prepared = try await client.prepareChangelogOverlay(onlyIfUnseen: false)

        #expect(prepared != nil)
        let changelogRequests = (recorded.value ?? []).filter { $0.url?.path.contains("/changelog") == true }
        #expect(changelogRequests.count == 1)
        let first = try #require(changelogRequests.first)
        let query = queryItems(of: first)
        #expect(query["limit"] == "10")
        #expect(query["cursor"] == nil)
    }

    @Test func selfLoadedOverlayRequestsSinglePageWithConfiguredEntryCountLimit() async throws {
        let (client, recorded) = mockChangelogAPIWithRequests(entryCount: 5)
        let content = await ChangelogOverlayView.fetchSelfLoadedContent(in: client)

        guard case .entries(let entries, let appearance)? = content else {
            Issue.record("Expected .entries, got \(String(describing: content))")
            return
        }
        #expect(entries.map(\.id) == ["e_presentation_1"])
        #expect(appearance.changelogOverlay.entryCount == 5)

        let changelogRequests = (recorded.value ?? []).filter { $0.url?.path.contains("/changelog") == true }
        #expect(changelogRequests.count == 1)
        let first = try #require(changelogRequests.first)
        let query = queryItems(of: first)
        #expect(query["limit"] == "5")
        #expect(query["cursor"] == nil)
    }

    @Test func prepareAndSelfLoadedOverlayIsolateFailureOnSubsequentPages() async throws {
        let pageCounter = CaptureBox<Int>()
        pageCounter.value = 0
        let (client, recorded) = mockChangelogAPIWithRequests(entryCount: 3) { _ in
            let count = (pageCounter.value ?? 0) + 1
            pageCounter.value = count
            if count <= 2 {
                // Page 1 for prepare and page 1 for selfLoaded both succeed
                return (makeHTTPResponse(), try encodeJSON([
                    "entries": [makeDefaultEntry()],
                    "hasMore": true,
                    "nextCursor": "hypothetical_page_2"
                ]))
            }
            // A hypothetical second page would fail with 500
            return (makeHTTPResponse(status: 500), try encodeJSON(["error": "hypothetical page 2 failure"]))
        }

        // prepareChangelogOverlay succeeds because it never fetches page 2
        let prepared = try await client.prepareChangelogOverlay(onlyIfUnseen: false)
        #expect(prepared?.entries.map(\.id) == ["e_presentation_1"])

        // fetchSelfLoadedContent also succeeds and never fetches page 2
        let content = await ChangelogOverlayView.fetchSelfLoadedContent(in: client)
        guard case .entries(let entries, _)? = content else {
            Issue.record("Expected .entries, got \(String(describing: content))")
            return
        }
        #expect(entries.map(\.id) == ["e_presentation_1"])

        let changelogRequests = (recorded.value ?? []).filter { $0.url?.path.contains("/changelog") == true }
        #expect(changelogRequests.count == 2)
    }
}

// MARK: - Stubs

@MainActor
private final class RefusedStubPresenter: ChangelogOverlayPresenter {
    func present(
        client: FeedbackClient,
        entries: [ChangelogEntry],
        appearance: SdkAppearance,
        context: ChangelogOverlayPresentationContext
    ) async {
        context.markRefused()
    }
}

@MainActor
private final class SuccessfulStubPresenter: ChangelogOverlayPresenter {
    private(set) var hasPresented = false

    func present(
        client: FeedbackClient,
        entries: [ChangelogEntry],
        appearance: SdkAppearance,
        context: ChangelogOverlayPresentationContext
    ) async {
        hasPresented = true
        context.markPresented()
        context.markDismissed()
    }
}

@MainActor
private final class SilentFailureStubPresenter: ChangelogOverlayPresenter {
    func present(
        client: FeedbackClient,
        entries: [ChangelogEntry],
        appearance: SdkAppearance,
        context: ChangelogOverlayPresentationContext
    ) async {
        // Deliberately drops the call: neither marks presented, dismissed, nor refused.
    }
}

@MainActor
private final class DelayedDismissStubPresenter: ChangelogOverlayPresenter {
    func present(
        client: FeedbackClient,
        entries: [ChangelogEntry],
        appearance: SdkAppearance,
        context: ChangelogOverlayPresentationContext
    ) async {
        // Marks presented immediately (cancelling the watchdog),
        // then delays longer than the watchdog timeout before dismissing.
        context.markPresented()
        try? await Task.sleep(nanoseconds: 80_000_000)
        context.markDismissed()
    }
}

// MARK: - Helpers

private func makeDefaultEntry() -> [String: Any] {
    [
        "id": "e_presentation_1",
        "title": "Version 1.0",
        "body": "First release",
        "versionLabel": "1.0.0",
        "publishedAt": "2026-01-01T00:00:00.000Z",
        "linkedRequests": []
    ]
}

private struct TimeoutError: Error {}

private func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        guard let result = try await group.next() else {
            throw TimeoutError()
        }
        group.cancelAll()
        return result
    }
}

private func queryItems(of request: URLRequest) -> [String: String] {
    guard let url = request.url,
          let items = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems else {
        return [:]
    }
    return Dictionary(items.compactMap { item in
        item.value.map { (item.name, $0) }
    }, uniquingKeysWith: { first, _ in first })
}
