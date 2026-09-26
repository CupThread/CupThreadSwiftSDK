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

/// CONC-7 / issue #211: submission actions in views (feedback composer,
/// feature request composer, changelog subscribe, and comment submit) must
/// filter out cancellation errors using `guard !error.isSdkCancellation else { return }`.
/// When a submission is interrupted by view dismissal or task cancellation,
/// cancellation errors must be treated as normal interruptions and must not
/// populate user-facing error banners or toasts.
@Suite("SubmitCancellationSuppression")
struct SubmitCancellationSuppressionTests {
    @Test func cancellationErrorDoesNotPopulateFriendlyErrorUI() {
        let cancellation = CancellationError()
        let urlCancellation = URLError(.cancelled)

        #expect(cancellation.isSdkCancellation)
        #expect(urlCancellation.isSdkCancellation)
    }

    @Test func submitCancellationClassifierDistinguishesFromRealErrors() {
        let realErrors: [Error] = [
            URLError(.notConnectedToInternet),
            URLError(.timedOut),
            URLError(.networkConnectionLost),
            FeedbackClientError.unexpectedStatus(code: 500, message: "boom", requestId: nil),
            FeedbackClientError.forbidden(message: "permission denied", requestId: nil),
            FeedbackClientError.authenticationRequired
        ]

        for error in realErrors {
            #expect(!error.isSdkCancellation, "Real error \(error) must not classify as cancellation")
        }

        let cancellations: [Error] = [
            CancellationError(),
            URLError(.cancelled)
        ]

        for error in cancellations {
            #expect(error.isSdkCancellation, "Cancellation error \(error) must classify as cancellation")
        }
    }

    @Test func userFacingSubmitSurfacesFilterSdkCancellation() throws {
        var directory = URL(fileURLWithPath: #filePath)
        var sourceDir: URL?
        for _ in 0..<6 {
            directory.deleteLastPathComponent()
            let candidate = directory
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("CupThreadFeedback", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                sourceDir = candidate
                break
            }
        }
        let sourcesURL = try #require(sourceDir, "Could not locate Sources/CupThreadFeedback")

        let targetFileNames = [
            "FeedbackComposerView.swift",
            "FeatureRequestComposeView.swift",
            "ChangelogSubscribeView.swift",
            "CommentsView.swift"
        ]

        for fileName in targetFileNames {
            let fileURL = sourcesURL.appendingPathComponent(fileName)
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(
                content.contains("guard !error.isSdkCancellation else { return }"),
                "\(fileName) must filter out isSdkCancellation in submit catch blocks to prevent error banners on cancellation"
            )
        }
    }
}
