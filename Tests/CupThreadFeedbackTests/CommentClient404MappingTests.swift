import Foundation
import Testing
@testable import CupThreadFeedback

// Issue #438 added 404 mapping when posting a comment on a deleted or
// comment-disabled feature request. Issue #530 narrows it to the same
// envelope-only contract as the GET path (BUG-31): only a documented JSON
// error envelope with a non-empty `error` string means
// `commentsUnavailable`; router-fallback 404s (text/plain, empty body, or
// JSON without an error string) surface as `.unexpectedStatus` so an
// infrastructure misconfiguration is not misreported as a per-request
// comments-disabled state.
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

    @Test func postCommentMaps404EnvelopeMessageTrimmed() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 404, headers: ["X-Request-Id": "req-trimmed-404"]),
                try encodeJSON(["error": "  Comments are disabled  "])
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
            #expect(message == "Comments are disabled")
            #expect(requestId == "req-trimmed-404")
        }
    }

    @Test func postCommentSurfacesPlainTextRouter404AsUnexpectedStatus() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 404, headers: ["X-Request-Id": "req-router-404"]),
                Data("404 Not Found".utf8)
            )
        }

        do {
            _ = try await Self.makeAPIClient().postComment(
                featureRequestId: "fr-123",
                draft: CommentDraft(body: "Test"),
                userToken: "token-123"
            )
            Issue.record("Expected unexpectedStatus")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, let message, let requestId) = error else {
                Issue.record("Expected .unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 404)
            #expect(message == "404 Not Found")
            #expect(requestId == "req-router-404")
        }
    }

    @Test func postCommentSurfacesEmptyBody404AsUnexpectedStatus() async throws {
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
            Issue.record("Expected unexpectedStatus")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, _, let requestId) = error else {
                Issue.record("Expected .unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 404)
            #expect(requestId == "req-empty-404")
        }
    }

    @Test func postCommentSurfacesWhitespaceOnlyBody404AsUnexpectedStatus() async throws {
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
            Issue.record("Expected unexpectedStatus")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, _, _) = error else {
                Issue.record("Expected .unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 404)
        }
    }

    @Test func postCommentSurfacesBlankEnvelopeErrorAsUnexpectedStatus() async throws {
        // The envelope shape alone is not enough: an empty (`nilIfEmpty`)
        // error string cannot describe a comments-disabled verdict, so the
        // 404 must not consume the load-path presentation (BUG-31, #530).
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 404, headers: ["X-Request-Id": "req-blank-envelope"]),
                try encodeJSON(["error": "   ", "code": "comments_disabled"])
            )
        }

        do {
            _ = try await Self.makeAPIClient().postComment(
                featureRequestId: "fr-123",
                draft: CommentDraft(body: "Test"),
                userToken: "token-123"
            )
            Issue.record("Expected unexpectedStatus")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, _, let requestId) = error else {
                Issue.record("Expected .unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 404)
            #expect(requestId == "req-blank-envelope")
        }
    }

    @Test func postCommentSurfacesEnvelopeWithoutErrorFieldAsUnexpectedStatus() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 404, headers: ["X-Request-Id": "req-no-error-field"]),
                try encodeJSON(["code": "comments_disabled"])
            )
        }

        do {
            _ = try await Self.makeAPIClient().postComment(
                featureRequestId: "fr-123",
                draft: CommentDraft(body: "Test"),
                userToken: "token-123"
            )
            Issue.record("Expected unexpectedStatus")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, _, let requestId) = error else {
                Issue.record("Expected .unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 404)
            #expect(requestId == "req-no-error-field")
        }
    }
}
