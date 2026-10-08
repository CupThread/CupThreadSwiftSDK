import Foundation
import Testing
@testable import CupThreadFeedback

// Issue #237: a 400 `invalid_parent` rejection means the reply target is
// stale server-side (hidden, deleted, or on a different feature request).
// The client must surface the typed error with curated copy, and the
// composer must clear its reply target so a retry posts a top-level
// comment instead of re-failing on the same stale parent.
@Suite("InvalidParent Error Mapping", .serialized)
struct InvalidParentErrorMappingTests {
    static let apiHost = "invalid-parent.example.com"

    static func makeAPIClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(apiHost)")!)
    }

    // MARK: - Wire mapping

    @Test func postCommentMapsInvalidParentEnvelopeToTypedError() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 400, headers: ["X-Request-Id": "req-400-parent"]),
                try encodeJSON([
                    "error": "Parent comment is not available",
                    "code": "invalid_parent"
                ])
            )
        }

        do {
            _ = try await Self.makeAPIClient().postComment(
                featureRequestId: "fr-123",
                draft: CommentDraft(body: "Test", parentId: "c-hidden"),
                userToken: "token-123"
            )
            Issue.record("Expected invalidParent")
        } catch let error as FeedbackClientError {
            guard case .invalidParent(let message, let requestId) = error else {
                Issue.record("Expected .invalidParent, got \(error)")
                return
            }
            #expect(message == "Parent comment is not available")
            #expect(requestId == "req-400-parent")
            #expect(error.requestId == "req-400-parent")
            #expect(error.responseBody == nil, "raw server text must stay off responseBody")
        }
    }

    @Test func postCommentMapsInvalidParentEnvelopeWithoutRequestId() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 400),
                try encodeJSON(["error": "Parent comment is not available", "code": "invalid_parent"])
            )
        }

        do {
            _ = try await Self.makeAPIClient().postComment(
                featureRequestId: "fr-123",
                draft: CommentDraft(body: "Test", parentId: "c-hidden"),
                userToken: "token-123"
            )
            Issue.record("Expected invalidParent")
        } catch let error as FeedbackClientError {
            guard case .invalidParent(let message, let requestId) = error else {
                Issue.record("Expected .invalidParent, got \(error)")
                return
            }
            #expect(message == "Parent comment is not available")
            #expect(requestId == nil)
        }
    }

    @Test func other400sStayUnexpectedStatusForPostComment() async throws {
        // Only the documented `invalid_parent` envelope maps to the typed
        // error; any other 400 keeps the diagnostic unexpectedStatus.
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 400), try encodeJSON(["error": "Malformed request"]))
        }

        do {
            _ = try await Self.makeAPIClient().postComment(
                featureRequestId: "fr-123",
                draft: CommentDraft(body: "Test"),
                userToken: "token-123"
            )
            Issue.record("Expected unexpectedStatus")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, _, _) = error else {
                Issue.record("Expected unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 400)
        }
    }

    // MARK: - User-facing copy

    @Test func invalidParentRendersCuratedCopyWithoutServerText() {
        let error = FeedbackClientError.invalidParent(
            message: "<html>raw server error</html>",
            requestId: "req-com-1"
        )
        let expected = CupThreadStrings.tr("cupthread.comments.invalid_parent")
            + " (request id: req-com-1)"
        #expect(error.errorDescription == expected)
        #expect(!error.errorDescription!.contains("<html>"))
        #expect(!error.errorDescription!.contains("Parent comment is not available"))
        #expect(FriendlyError.message(for: error) == expected)
    }

    @Test func invalidParentDescriptionOmitsRequestIdWhenAbsent() throws {
        let error = FeedbackClientError.invalidParent(message: "gone", requestId: nil)
        let desc = try #require(error.errorDescription)
        #expect(desc == CupThreadStrings.tr("cupthread.comments.invalid_parent"))
        #expect(!desc.contains("request id"))
        #expect(!desc.contains("cupthread.comments.invalid_parent"))
    }

    // MARK: - Reply-target recovery

    @Test func invalidatesReplyTargetForInvalidParentOnly() {
        #expect(
            CommentsView.invalidatesReplyTarget(
                for: FeedbackClientError.invalidParent(message: "gone", requestId: nil)
            )
        )
        #expect(
            !CommentsView.invalidatesReplyTarget(
                for: FeedbackClientError.unexpectedStatus(code: 400, message: "gone", requestId: nil)
            )
        )
        #expect(
            !CommentsView.invalidatesReplyTarget(
                for: FeedbackClientError.commentsUnavailable(message: "gone", requestId: nil)
            )
        )
        #expect(!CommentsView.invalidatesReplyTarget(for: FeedbackClientError.authenticationRequired))
        #expect(!CommentsView.invalidatesReplyTarget(for: URLError(.timedOut)))
    }

    @Test func clearReplyTargetDropsReplyFieldsAndKeepsBody() {
        var draft = CommentDraft(
            body: "Still valid content",
            parentId: "c-parent",
            replyToClerkId: "u_ab12cd34",
            replyToAuthorName: "Ada"
        )
        draft.clearReplyTarget()
        #expect(draft.body == "Still valid content")
        #expect(draft.parentId == nil)
        #expect(draft.replyToClerkId == nil)
        #expect(draft.replyToAuthorName == nil)
        #expect(draft.hasContent, "the typed body must survive the reply-target reset")
    }
}
