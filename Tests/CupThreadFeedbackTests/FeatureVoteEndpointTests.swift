import Foundation
import Testing
@testable import CupThreadFeedback

@Suite("FeatureVoteEndpoint", .serialized)
struct FeatureVoteEndpointTests {
    static let apiHost = "voteapi.example.com"

    static func makeAPIClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(apiHost)")!)
    }

    @Test func castVoteHitsVoteEndpointWithPOST() async throws {
        let captureUrl = CaptureBox<URL>()
        let captureMethod = CaptureBox<String>()
        let captureBody = CaptureBox<Data>()

        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            captureUrl.value = request.url
            captureMethod.value = request.httpMethod
            captureBody.value = bodyData(from: request)

            let json: [String: Any] = [
                "voted": true,
                "voteCount": 15
            ]
            return (makeHTTPResponse(status: 200), try encodeJSON(json))
        }

        let result = try await Self.makeAPIClient().castVote(
            featureRequestId: "fr-cast-1",
            userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f"
        )

        let url = try #require(captureUrl.value)
        #expect(url.path == "/api/v1/feature-requests/fr-cast-1/vote")
        #expect(captureMethod.value == "POST")

        let data = try #require(captureBody.value)
        let dict = try #require(parseJSONDict(data))
        #expect(dict["appKey"] as? String == "app_testkey123456")
        #expect(dict["userToken"] as? String == "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f")

        #expect(result.voted == true)
        #expect(result.voteCount == 15)
    }

    @Test func removeVoteHitsVoteEndpointWithDELETE() async throws {
        let captureUrl = CaptureBox<URL>()
        let captureMethod = CaptureBox<String>()
        let captureBody = CaptureBox<Data>()

        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            captureUrl.value = request.url
            captureMethod.value = request.httpMethod
            captureBody.value = bodyData(from: request)

            let json: [String: Any] = [
                "voted": false,
                "voteCount": 14
            ]
            return (makeHTTPResponse(status: 200), try encodeJSON(json))
        }

        let result = try await Self.makeAPIClient().removeVote(
            featureRequestId: "fr-rem-1",
            userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f"
        )

        let url = try #require(captureUrl.value)
        #expect(url.path == "/api/v1/feature-requests/fr-rem-1/vote")
        #expect(captureMethod.value == "DELETE")

        let data = try #require(captureBody.value)
        let dict = try #require(parseJSONDict(data))
        #expect(dict["appKey"] as? String == "app_testkey123456")
        #expect(dict["userToken"] as? String == "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f")

        #expect(result.voted == false)
        #expect(result.voteCount == 14)
    }

    // MARK: - 404 mapping (issue #413, API-27)

    // Voting on a deleted, unapproved, or never-existing request is answered
    // with the documented JSON 404 envelope; it must surface as the typed
    // `.featureRequestNotFound` (with the echoed `X-Request-Id`) so callers
    // can act on "gone for good" instead of catching `.unexpectedStatus`.

    @Test func castVoteMapsJSONEnvelope404ToFeatureRequestNotFound() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 404, headers: ["X-Request-Id": "req-vote-404"]),
                try encodeJSON(["error": "Feature request not found"])
            )
        }

        do {
            _ = try await Self.makeAPIClient().castVote(featureRequestId: "missing-fr", userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f")
            Issue.record("Expected featureRequestNotFound")
        } catch let error as FeedbackClientError {
            guard case .featureRequestNotFound(let message, let requestId) = error else {
                Issue.record("Expected .featureRequestNotFound, got \(error)")
                return
            }
            #expect(message == "Feature request not found")
            #expect(requestId == "req-vote-404")
        }
    }

    @Test func removeVoteMapsJSONEnvelope404ToFeatureRequestNotFound() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 404, headers: ["X-Request-Id": "req-unvote-404"]),
                try encodeJSON(["error": "Feature request not found"])
            )
        }

        do {
            _ = try await Self.makeAPIClient().removeVote(featureRequestId: "missing-fr", userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f")
            Issue.record("Expected featureRequestNotFound")
        } catch let error as FeedbackClientError {
            guard case .featureRequestNotFound(let message, let requestId) = error else {
                Issue.record("Expected .featureRequestNotFound, got \(error)")
                return
            }
            #expect(message == "Feature request not found")
            #expect(requestId == "req-unvote-404")
        }
    }

    // Production's router-fallback 404 is text/plain "404 Not Found" (deploy
    // skew, wrong baseURL) — it carries no envelope and must keep surfacing
    // as `.unexpectedStatus`, not as the typed missing-request error.

    @Test func castVoteMapsRouterFallback404ToUnexpectedStatus() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 404, headers: ["Content-Type": "text/plain"]),
                Data("404 Not Found".utf8)
            )
        }

        do {
            _ = try await Self.makeAPIClient().castVote(featureRequestId: "fr-42", userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f")
            Issue.record("Expected unexpectedStatus")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, let message, _) = error else {
                Issue.record("Expected .unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 404)
            #expect(message == "404 Not Found")
        }
    }

    @Test func removeVoteMapsEnvelope404WithoutErrorFieldToUnexpectedStatus() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 404), try encodeJSON(["message": "not found"]))
        }

        do {
            _ = try await Self.makeAPIClient().removeVote(featureRequestId: "fr-42", userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f")
            Issue.record("Expected unexpectedStatus")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, _, _) = error else {
                Issue.record("Expected .unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 404)
        }
    }
}
