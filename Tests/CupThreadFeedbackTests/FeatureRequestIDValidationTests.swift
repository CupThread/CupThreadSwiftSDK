import Foundation
import Testing
@testable import CupThreadFeedback

// Issue #426: CommentClient and FeatureRequestClient interpolated an
// unvalidated `featureRequestId` straight into the URL path, so a blank or
// whitespace-only id produced a futile network round trip that the gateway
// answers with 404/400 — which fetchComments/postComment then map to
// `commentsUnavailable`, misleading callers into thinking comments are
// disabled. All three entry points now trim and reject empty ids locally
// (matching `fetchFeatureRequest(id:)`) before any request is built.
@Suite("FeatureRequestIDValidation", .serialized)
struct FeatureRequestIDValidationTests {
    static let apiHost = "request-id-validation.example.com"

    static func makeAPIClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(apiHost)")!)
    }

    // MARK: - fetchComments

    @Test("fetchComments rejects blank feature request ids locally with no network call")
    func fetchCommentsRejectsBlankIDs() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), Data())
        }

        for blankID in ["", "   ", " \n\t "] {
            await #expect(throws: FeedbackClientError.invalidResponse) {
                _ = try await Self.makeAPIClient().fetchComments(featureRequestId: blankID, limit: 20)
            }
        }
        #expect(capture.value == nil, "A blank id must be rejected before any request is sent")
    }

    @Test("fetchComments trims a padded id and requests the trimmed path")
    func fetchCommentsTrimsPaddedID() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            let payload: [String: Any] = [
                "comments": [],
                "total": 0,
                "hasMore": false,
                "nextCursor": NSNull()
            ]
            return (makeHTTPResponse(), try encodeJSON(payload))
        }

        let result = try await Self.makeAPIClient().fetchComments(featureRequestId: "  fr-trim-1  ", limit: 20)

        let request = try #require(capture.value)
        #expect(request.url?.path == "/api/v1/feature-requests/fr-trim-1/comments")
        #expect(result.total == 0)
    }

    // MARK: - postComment

    @Test("postComment rejects blank feature request ids locally with no network call")
    func postCommentRejectsBlankIDs() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), Data())
        }

        for blankID in ["", "   "] {
            await #expect(throws: FeedbackClientError.invalidResponse) {
                _ = try await Self.makeAPIClient().postComment(
                    featureRequestId: blankID,
                    draft: CommentDraft(body: "hello"),
                    userToken: "tok-1"
                )
            }
        }
        #expect(capture.value == nil, "A blank id must be rejected before any request is sent")
    }

    @Test("postComment trims a padded id and posts to the trimmed path")
    func postCommentTrimsPaddedID() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (
                makeHTTPResponse(),
                try encodeJSON([
                    "comment": [
                        "id": "c-1",
                        "featureRequestId": "fr-trim-2",
                        "body": "hello",
                        "createdAt": "2026-01-01T00:00:00.000Z"
                    ]
                ])
            )
        }

        let comment = try await Self.makeAPIClient().postComment(
            featureRequestId: "\tfr-trim-2 ",
            draft: CommentDraft(body: "hello"),
            userToken: "tok-1"
        )

        let request = try #require(capture.value)
        #expect(request.url?.path == "/api/v1/feature-requests/fr-trim-2/comments")
        #expect(comment.id == "c-1")
    }

    // MARK: - Voting (castVote / removeVote share sendVoteRequest)

    @Test("castVote rejects blank feature request ids locally with no network call")
    func castVoteRejectsBlankIDs() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["voted": true, "voteCount": 1]))
        }

        for blankID in ["", "   "] {
            await #expect(throws: FeedbackClientError.invalidResponse) {
                _ = try await Self.makeAPIClient().castVote(featureRequestId: blankID, userToken: "tok-1")
            }
        }
        #expect(capture.value == nil, "A blank id must be rejected before any request is sent")
    }

    @Test("removeVote rejects blank feature request ids locally with no network call")
    func removeVoteRejectsBlankIDs() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["voted": false, "voteCount": 0]))
        }

        for blankID in ["", "   "] {
            await #expect(throws: FeedbackClientError.invalidResponse) {
                _ = try await Self.makeAPIClient().removeVote(featureRequestId: blankID, userToken: "tok-1")
            }
        }
        #expect(capture.value == nil, "A blank id must be rejected before any request is sent")
    }

    @Test("removeVote trims a padded id and requests the trimmed path")
    func removeVoteTrimsPaddedID() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["voted": false, "voteCount": 3]))
        }

        let result = try await Self.makeAPIClient().removeVote(featureRequestId: " fr-trim-3\t", userToken: "tok-1")

        let request = try #require(capture.value)
        #expect(request.url?.path == "/api/v1/feature-requests/fr-trim-3/vote")
        #expect(request.httpMethod == "DELETE")
        #expect(result.voteCount == 3)
    }
}
