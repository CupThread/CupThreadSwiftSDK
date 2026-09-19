import Foundation
import Testing
@testable import CupThreadFeedback

/// #31: task cancellation — a search-debounce restart (`.task(id:)` cancels
/// the previous task on every keystroke) or a mid-load dismissal — is not a
/// failure. No SDK load surface may render it as a user-facing error.
@Suite("CancellationClassifier")
struct CancellationClassifierTests {
    @Test func cancellationErrorClassifiesAsCancellation() {
        #expect(CancellationError().isSdkCancellation)
    }

    @Test func cancelledURLErrorClassifiesAsCancellation() {
        // URLSession surfaces a torn-down request as URLError.cancelled,
        // whether the enclosing task was cancelled or the request itself
        // was cancelled underneath it.
        #expect(URLError(.cancelled).isSdkCancellation)
    }

    @Test func genuineURLErrorsDoNotClassifyAsCancellation() {
        #expect(!URLError(.notConnectedToInternet).isSdkCancellation)
        #expect(!URLError(.timedOut).isSdkCancellation)
    }

    @Test func typedClientErrorsDoNotClassifyAsCancellation() {
        let error = FeedbackClientError.unexpectedStatus(code: 500, message: "boom", requestId: nil)
        #expect(!error.isSdkCancellation)
    }

    @Test func unrelatedErrorsDoNotClassifyAsCancellation() {
        struct UnrelatedError: Error {}
        #expect(!UnrelatedError().isSdkCancellation)
        #expect(!NSError(domain: "test.cupthread", code: 1).isSdkCancellation)
    }
}

/// The overlay's self-loading fetch must report a cancelled load as "no
/// verdict" (`nil`), never as a failure the overlay would render.
@Suite("OverlaySelfLoadCancellation")
struct OverlaySelfLoadCancellationTests {
    static let apiHost = "overlay-cancellation.example.com"

    /// Succeeds the config fetch and fails the changelog fetch with the
    /// error URLSession surfaces for a torn-down request.
    private func setConfigSuccessChangelogCancelledHandler() throws {
        var payload = makeConfigJSON()
        payload["sdk"] = [
            "theme": "system",
            "features": ["changelog": true],
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
                throw URLError(.cancelled)
            }
            return (makeHTTPResponse(), try encodeJSON(payload))
        }
    }

    private func makeOverlayClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!)
    }

    @Test func cancelledChangelogFetchYieldsNoFailureState() async throws {
        try setConfigSuccessChangelogCancelledHandler()
        let client = makeOverlayClient()

        let content = await ChangelogOverlayView.fetchSelfLoadedContent(in: client)

        #expect(content == nil, "A cancelled fetch must not be reported as a failure")
    }

    @Test func cancelledLoadTaskYieldsNoFailureState() async throws {
        try setConfigSuccessChangelogCancelledHandler()
        let client = makeOverlayClient()

        let task = Task { await ChangelogOverlayView.fetchSelfLoadedContent(in: client) }
        task.cancel()
        let content = await task.value

        #expect(content == nil, "A cancelled overlay load must not be reported as a failure")
    }
}
