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
// Issue #614: every grammar-invalid id — on all four entry points — reports
// the same `.featureRequestNotFound(message: nil, requestId: nil)` locally,
// never `.invalidResponse` (which describes a malformed server response).
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
            await #expect(throws: FeedbackClientError.featureRequestNotFound(message: nil, requestId: nil)) {
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
            await #expect(throws: FeedbackClientError.featureRequestNotFound(message: nil, requestId: nil)) {
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

    // Issue #413 (API-27): vote ids are checked against the same
    // `FeatureRequestIDGrammar` as `fetchFeatureRequest(id:)` — an id that
    // cannot be a single opaque path segment can never name an existing
    // request, so it is reported as `.featureRequestNotFound` locally, with
    // no request built and no Turnstile token consumed.

    @Test("castVote rejects invalid feature request ids locally with no network call")
    func castVoteRejectsInvalidIDs() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["voted": true, "voteCount": 1]))
        }

        for invalidID in ["", "   ", " \n\t ", "../admin", "fr-1/vote", "fr 1", "%2e%2e", String(repeating: "a", count: 129)] {
            await #expect(throws: FeedbackClientError.featureRequestNotFound(message: nil, requestId: nil)) {
                _ = try await Self.makeAPIClient().castVote(featureRequestId: invalidID, userToken: "tok-1")
            }
        }
        #expect(capture.value == nil, "An invalid id must be rejected before any request is sent")
    }

    @Test("removeVote rejects invalid feature request ids locally with no network call")
    func removeVoteRejectsInvalidIDs() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["voted": false, "voteCount": 0]))
        }

        for invalidID in ["", "   ", "..", "fr-1/../../feedback", "id?next=1", String(repeating: "a", count: 129)] {
            await #expect(throws: FeedbackClientError.featureRequestNotFound(message: nil, requestId: nil)) {
                _ = try await Self.makeAPIClient().removeVote(featureRequestId: invalidID, userToken: "tok-1")
            }
        }
        #expect(capture.value == nil, "An invalid id must be rejected before any request is sent")
    }

    @Test("castVote rejects invalid ids without consulting the Turnstile provider")
    func castVoteRejectsInvalidIDsWithoutTurnstileConsultation() async throws {
        let consulted = CaptureBox<Bool>()
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["voted": true, "voteCount": 1]))
        }
        let client = FeedbackClient(
            configuration: FeedbackClientConfiguration(
                baseURL: URL(string: "https://\(Self.apiHost)")!,
                appKey: "app_testkey123456"
            ),
            session: makeMockSession(),
            turnstileTokenProvider: { _ in
                consulted.value = true
                return "tok-turnstile"
            }
        )

        // A single-use challenge must not be spent on an id that can never
        // name a request (API-27).
        await #expect(throws: FeedbackClientError.featureRequestNotFound(message: nil, requestId: nil)) {
            _ = try await client.castVote(featureRequestId: "../../admin", userToken: "tok-1")
        }
        #expect(consulted.value != true, "The Turnstile provider must not be consulted for an invalid id")
        #expect(capture.value == nil, "No request may be sent for an invalid id")
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

    // MARK: - One convention, four entry points (issue #614)

    /// The grammar-invalid-id rejection must be indistinguishable across all
    /// four id-bearing entry points: the same `.featureRequestNotFound` with
    /// no server text and no request id, so a host's
    /// `catch FeedbackClientError.featureRequestNotFound` branch behaves
    /// identically for a deep-linked id whichever surface loads it.
    @Test("a grammar-invalid id reports the same not-found error on every entry point")
    func grammarInvalidIDReportsSameErrorOnEveryEntryPoint() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(), Data("SHOULD NOT BE REACHED".utf8))
        }
        let client = Self.makeAPIClient()

        for invalidID in ["../test", "fr/1", "a?b", "a%2Fb", String(repeating: "a", count: 129)] {
            await #expect(throws: FeedbackClientError.featureRequestNotFound(message: nil, requestId: nil)) {
                _ = try await client.fetchFeatureRequest(id: invalidID)
            }
            await #expect(throws: FeedbackClientError.featureRequestNotFound(message: nil, requestId: nil)) {
                _ = try await client.castVote(featureRequestId: invalidID, userToken: "tok-1")
            }
            await #expect(throws: FeedbackClientError.featureRequestNotFound(message: nil, requestId: nil)) {
                _ = try await client.removeVote(featureRequestId: invalidID, userToken: "tok-1")
            }
            await #expect(throws: FeedbackClientError.featureRequestNotFound(message: nil, requestId: nil)) {
                _ = try await client.fetchComments(featureRequestId: invalidID, limit: 20)
            }
            await #expect(throws: FeedbackClientError.featureRequestNotFound(message: nil, requestId: nil)) {
                _ = try await client.postComment(
                    featureRequestId: invalidID,
                    draft: CommentDraft(body: "hello"),
                    userToken: "tok-1"
                )
            }
        }
    }
}
