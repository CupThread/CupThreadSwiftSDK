import Foundation
import Testing
@testable import CupThreadFeedback

// Issue #438: when posting a comment on a deleted or comment-disabled
// feature request, the server responds with HTTP 404. The client must map
// this to the typed `FeedbackClientError.commentsUnavailable` error, and
// `CommentsView.submitComment()` must collapse the composer.
@Suite("CommentClient 404 Mapping", .serialized)
struct CommentClient404MappingTests {
    static let apiHost = "comment-404.example.com"

    static func makeAPIClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(apiHost)")!)
    }

    @Test func postCommentMaps404ToCommentsUnavailable() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 404, headers: ["X-Request-Id": "req-404-comment"]),
                try encodeJSON([
                    "error": "Comments are disabled for this feature request",
                    "code": "comments_disabled"
                ])
            )
        }

        do {
            _ = try await Self.makeAPIClient().postComment(
                featureRequestId: "fr-123",
                draft: CommentDraft(body: "Test"),
                userToken: "token-123"
            )
            Issue.record("Expected commentsUnavailable")
        } catch let error as FeedbackClientError {
            guard case .commentsUnavailable(let message, let requestId) = error else {
                Issue.record("Expected .commentsUnavailable, got \(error)")
                return
            }
            #expect(message == "Comments are disabled for this feature request")
            #expect(requestId == "req-404-comment")
            #expect(error.requestId == "req-404-comment")
            #expect(error.responseBody == nil)
            let expectedMsg = CupThreadStrings.tr("cupthread.error.comments_unavailable")
                + " (request id: req-404-comment)"
            #expect(error.errorDescription == expectedMsg)
            #expect(FriendlyError.message(for: error) == expectedMsg)
        }
    }

    @Test func postCommentMaps404WithoutRequestId() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 404),
                try encodeJSON([
                    "error": "Comments are disabled for this feature request",
                    "code": "comments_disabled"
                ])
            )
        }

        do {
            _ = try await Self.makeAPIClient().postComment(
                featureRequestId: "fr-123",
                draft: CommentDraft(body: "Test"),
                userToken: "token-123"
            )
            Issue.record("Expected commentsUnavailable")
        } catch let error as FeedbackClientError {
            guard case .commentsUnavailable(let message, let requestId) = error else {
                Issue.record("Expected .commentsUnavailable, got \(error)")
                return
            }
            #expect(message == "Comments are disabled for this feature request")
            #expect(requestId == nil)
            #expect(error.requestId == nil)
            #expect(
                FriendlyError.message(for: error) ==
                CupThreadStrings.tr("cupthread.error.comments_unavailable")
            )
        }
    }

    @Test func postCommentMaps404PlainTextToCommentsUnavailable() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 404),
                Data("Feature request not found".utf8)
            )
        }

        do {
            _ = try await Self.makeAPIClient().postComment(
                featureRequestId: "fr-123",
                draft: CommentDraft(body: "Test"),
                userToken: "token-123"
            )
            Issue.record("Expected commentsUnavailable")
        } catch let error as FeedbackClientError {
            guard case .commentsUnavailable(let message, let requestId) = error else {
                Issue.record("Expected .commentsUnavailable, got \(error)")
                return
            }
            #expect(message == "Feature request not found")
            #expect(requestId == nil)
        }
    }

    @Test func postCommentMaps404EmptyBodyToCommentsUnavailable() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 404, headers: ["X-Request-Id": "req-empty-404"]),
                Data()
            )
        }

        do {
            _ = try await Self.makeAPIClient().postComment(
                featureRequestId: "fr-123",
                draft: CommentDraft(body: "Test"),
                userToken: "token-123"
            )
            Issue.record("Expected commentsUnavailable")
        } catch let error as FeedbackClientError {
            guard case .commentsUnavailable(let message, let requestId) = error else {
                Issue.record("Expected .commentsUnavailable, got \(error)")
                return
            }
            #expect(message == nil)
            #expect(requestId == "req-empty-404")
        }
    }

    @Test func postCommentMaps404WhitespaceOnlyBodyToCommentsUnavailable() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 404),
                Data("   \n\t  ".utf8)
            )
        }

        do {
            _ = try await Self.makeAPIClient().postComment(
                featureRequestId: "fr-123",
                draft: CommentDraft(body: "Test"),
                userToken: "token-123"
            )
            Issue.record("Expected commentsUnavailable")
        } catch let error as FeedbackClientError {
            guard case .commentsUnavailable(let message, _) = error else {
                Issue.record("Expected .commentsUnavailable, got \(error)")
                return
            }
            #expect(message == nil)
        }
    }
}
