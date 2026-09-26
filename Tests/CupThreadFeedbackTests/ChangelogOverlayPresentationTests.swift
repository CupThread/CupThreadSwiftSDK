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
