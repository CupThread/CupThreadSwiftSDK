import Foundation
import Testing
@testable import CupThreadFeedback

// Issue #412 (BUG-31): `fetchComments` and `postComment` interpolated a
// caller-supplied `featureRequestId` into the URL path after only an
// emptiness check (#426), so traversal-style ids (`../test`, `fr/1`, …)
// reached the wire while `Authorization: Bearer` and `X-User-Token` headers
// were attached; `postComment` dispatched whitespace-only bodies that the
// server could only answer with `400 Validation failed`; and `fetchComments`
// mapped *every* 404 — including bare router fallbacks — to
// `commentsUnavailable`, misreporting infrastructure misconfiguration as a
// per-request comments-disabled state. All three are now rejected or
// disambiguated locally. Since issue #614 a grammar-invalid id is reported
// as `.featureRequestNotFound` — the same convention as
// `fetchFeatureRequest` and the vote endpoints — and an empty body as
// `.invalidInput(field: "body")`, because `.invalidResponse` describes a
// malformed server response and nothing was sent.
@Suite("CommentClient Local Validation", .serialized)
struct CommentClientLocalValidationTests {
    static let apiHost = "comment-local-validation.example.com"

    static func makeAPIClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(apiHost)")!)
    }

    /// Ids that can never name a real feature request: path separators,
    /// `..` segments, query/fragment/percent characters, non-ASCII, and
    /// oversized input — the same untrusted deep-link shapes
    /// `FeatureRequestIDGrammar` has rejected since API-24.
    static let invalidIDs = [
        "../test",
        "fr/1",
        "..",
        "a?b",
        "a#b",
        "a%2Fb",
        "请求",
        String(repeating: "a", count: 129)
    ]

    // MARK: - featureRequestId grammar

    @Test("fetchComments rejects invalid feature request ids locally with no network call")
    func fetchCommentsRejectsInvalidIDsWithoutNetwork() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), Data())
        }

        for id in Self.invalidIDs {
            await #expect(throws: FeedbackClientError.featureRequestNotFound(message: nil, requestId: nil)) {
                _ = try await Self.makeAPIClient().fetchComments(featureRequestId: id, limit: 20)
            }
        }
        #expect(capture.value == nil, "An invalid id must be rejected before any request is sent")
    }

    @Test("postComment rejects invalid feature request ids locally with no network call")
    func postCommentRejectsInvalidIDsWithoutNetwork() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), Data())
        }

        for id in Self.invalidIDs {
            await #expect(throws: FeedbackClientError.featureRequestNotFound(message: nil, requestId: nil)) {
                _ = try await Self.makeAPIClient().postComment(
                    featureRequestId: id,
                    draft: CommentDraft(body: "hello"),
                    userToken: "tok-1"
                )
            }
        }
        #expect(capture.value == nil, "An invalid id must be rejected before any request is sent")
    }

    // MARK: - whitespace-only comment bodies

    @Test("postComment rejects empty and whitespace-only bodies locally with no network call")
    func postCommentRejectsWhitespaceOnlyBodies() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), Data())
        }

        for body in ["", "   ", "\n\t  ", " \u{00A0} "] {
            await #expect(throws: FeedbackClientError.invalidInput(field: "body")) {
                _ = try await Self.makeAPIClient().postComment(
                    featureRequestId: "fr-123",
                    draft: CommentDraft(body: body),
                    userToken: "tok-1"
                )
            }
        }
        #expect(capture.value == nil, "A whitespace-only body must be rejected before any request is sent")
    }

    @Test("postComment still trims and sends a padded body")
    func postCommentTrimsPaddedBody() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (
                makeHTTPResponse(),
                try encodeJSON([
                    "comment": [
                        "id": "c-9",
                        "featureRequestId": "fr-123",
                        "body": "hello",
                        "createdAt": "2026-01-01T00:00:00.000Z"
                    ]
                ])
            )
        }

        let comment = try await Self.makeAPIClient().postComment(
            featureRequestId: "fr-123",
            draft: CommentDraft(body: "  hello \n"),
            userToken: "tok-1"
        )

        #expect(comment.id == "c-9")
        let request = try #require(capture.value)
        let sentBody = try #require(bodyData(from: request))
        let json = try #require(try JSONSerialization.jsonObject(with: sentBody) as? [String: Any])
        #expect(json["body"] as? String == "hello")
    }

    // MARK: - 404 disambiguation in fetchComments

    @Test("fetchComments maps a JSON-envelope 404 to commentsUnavailable with the echoed request id")
    func fetchCommentsMapsEnvelope404ToCommentsUnavailable() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 404, headers: ["X-Request-Id": "req-env-404"]),
                try encodeJSON([
                    "error": "  Comments are disabled for this feature request  ",
                    "code": "comments_disabled"
                ])
            )
        }

        do {
            _ = try await Self.makeAPIClient().fetchComments(featureRequestId: "fr-123", limit: 20)
            Issue.record("Expected commentsUnavailable")
        } catch let error as FeedbackClientError {
            guard case .commentsUnavailable(let message, let requestId) = error else {
                Issue.record("Expected .commentsUnavailable, got \(error)")
                return
            }
            #expect(message == "Comments are disabled for this feature request")
            #expect(requestId == "req-env-404")
        }
    }

    @Test("fetchComments surfaces a text/plain router 404 as unexpectedStatus")
    func fetchCommentsMapsRouter404ToUnexpectedStatus() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 404, headers: ["X-Request-Id": "req-router-404"]),
                Data("404 Not Found".utf8)
            )
        }

        do {
            _ = try await Self.makeAPIClient().fetchComments(featureRequestId: "fr-123", limit: 20)
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

    @Test("fetchComments surfaces an empty-body 404 as unexpectedStatus")
    func fetchCommentsMapsEmptyBody404ToUnexpectedStatus() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 404, headers: ["X-Request-Id": "req-empty-404"]),
                Data()
            )
        }

        do {
            _ = try await Self.makeAPIClient().fetchComments(featureRequestId: "fr-123", limit: 20)
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
}
