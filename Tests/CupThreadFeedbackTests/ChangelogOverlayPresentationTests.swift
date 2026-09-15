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

    private func mockChangelogAPI(changelogEnabled: Bool = true, entries: [[String: Any]] = [makeDefaultEntry()]) {
        var payload = makeConfigJSON()
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
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            if request.url?.path.contains("/changelog") == true {
                return (makeHTTPResponse(), try encodeJSON(["entries": entries]))
            }
            return (makeHTTPResponse(), try encodeJSON(payload))
        }
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
