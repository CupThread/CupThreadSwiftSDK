import Foundation
import SwiftUI
import Testing
@testable import CupThreadFeedback

// Issue #410 (BUG-30): after a failed initial fetch, `loadState.loadError`
// hands the scroll view to `LoadErrorView`. The composer below it stayed
// fully functional, and a comment submitted through it was appended to the
// model — but the stale error verdict kept owning the surface, so the user's
// comment stayed invisible until a manual retry. The submit success path
// must retire the stale verdict; the failure path must leave it untouched.
@Suite("CommentsView submit clears full-screen load error")
struct CommentsViewSubmitLoadErrorTests {
    // MARK: - Regression: success path retires the stale error verdict

    @Test func submitSuccessPathClearsLoadErrorBeforeResettingTheDraft() throws {
        // SwiftUI `@State` writes are not observable on a unit-constructed
        // view, so the mutation is pinned with the source-scan pattern
        // (`successfulSubmitPathResetsDraftBeforeCallback`): the clear must
        // sit inside the success `do` block, after the append and before the
        // draft reset — and must be the only such write in the view, so the
        // `catch` block can never clear a verdict it did not earn.
        let content = try String(
            contentsOf: try #require(Self.commentsViewSourceURL()),
            encoding: .utf8
        )

        let append = try #require(
            content.range(of: "comments.append(newComment)"),
            "the append anchor was renamed; update this scan"
        )
        let draftReset = try #require(
            content.range(of: "draft.body = \"\"", range: append.upperBound..<content.endIndex),
            "the draft reset anchor was renamed; update this scan"
        )
        let between = content[append.upperBound..<draftReset.lowerBound]
        #expect(
            between.contains("loadState.loadError = nil"),
            "a successful submission must clear the full-screen load error so the appended comment becomes visible (issue #410)"
        )

        let clearWrites = content.components(separatedBy: "loadState.loadError = nil").count - 1
        #expect(
            clearWrites == 1,
            "expected exactly one loadError clear (the submit success path), found \(clearWrites)"
        )
    }

    // MARK: - End-to-end flow: load failure, then a successful submit

    @Test @MainActor func successfulSubmitAfterLoadFailurePostsTheComposerBody() async throws {
        // The full regression flow against mocked transports: the initial
        // fetch fails (full-screen error on record), the user submits through
        // the still-presented composer, and the POST carries the draft body.
        let host = "comments-bug30-success.test.example.com"
        MockURLProtocol.setHandler(forHost: host) { _ in
            (makeHTTPResponse(status: 503), try encodeJSON(["error": "unavailable"]))
        }
        defer { MockURLProtocol.setHandler(forHost: host, nil) }

        let capture = CaptureBox<URLRequest>()
        let view = CommentsView(
            client: makeClient(baseURL: URL(string: "https://\(host)")!),
            userToken: "token_123",
            featureRequestId: "fr_bug30",
            featureRequestTitle: "Title",
            preResolvedAuthentication: true,
            initialDraft: CommentDraft(body: "First comment")
        )

        await view.loadComments()

        MockURLProtocol.setHandler(forHost: host) { request in
            capture.value = request
            return (makeHTTPResponse(status: 201), try Self.createdCommentEnvelope())
        }

        await view.submitComment()

        let request = try #require(capture.value, "a successful submit must issue the POST")
        #expect(request.url?.path == "/api/v1/feature-requests/fr_bug30/comments")
        let body = try #require(bodyData(from: request))
        let payload = try #require(parseJSONDict(body))
        #expect(payload["body"] as? String == "First comment")
    }

    @Test @MainActor func successfulSubmitWithoutPriorLoadFailurePostsCleanly() async throws {
        // The fix must not disturb the clean path: a submit on a surface
        // that never saw a load error still posts, and leaves no error
        // verdict behind for a later surface decision to trip over.
        let host = "comments-bug30-clean.test.example.com"
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: host) { request in
            capture.value = request
            return (makeHTTPResponse(status: 201), try Self.createdCommentEnvelope())
        }
        defer { MockURLProtocol.setHandler(forHost: host, nil) }

        let view = CommentsView(
            client: makeClient(baseURL: URL(string: "https://\(host)")!),
            userToken: "token_123",
            featureRequestId: "fr_bug30",
            featureRequestTitle: "Title",
            preResolvedAuthentication: true,
            initialDraft: CommentDraft(body: "Clean path comment")
        )

        await view.submitComment()

        let request = try #require(capture.value, "a successful submit must issue the POST")
        let body = try #require(bodyData(from: request))
        let payload = try #require(parseJSONDict(body))
        #expect(payload["body"] as? String == "Clean path comment")
    }

    // MARK: - Fixtures

    /// The created-comment success envelope the server answers with (`201`).
    private static func createdCommentEnvelope() throws -> Data {
        try encodeJSON(["comment": [
            "id": "c-bug30",
            "featureRequestId": "fr_bug30",
            "body": "First comment",
            "authorName": NSNull(),
            "createdAt": "2026-01-01T00:00:00.000Z"
        ]])
    }

    private static func commentsViewSourceURL() -> URL? {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            directory.deleteLastPathComponent()
            let candidate = directory
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("CupThreadFeedback", isDirectory: true)
                .appendingPathComponent("CommentsView.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
