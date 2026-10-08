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
            userToken: "tok-cast"
        )

        let url = try #require(captureUrl.value)
        #expect(url.path == "/api/v1/feature-requests/fr-cast-1/vote")
        #expect(captureMethod.value == "POST")

        let data = try #require(captureBody.value)
        let dict = try #require(parseJSONDict(data))
        #expect(dict["appKey"] as? String == "app_testkey123456")
        #expect(dict["userToken"] as? String == "tok-cast")

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
            userToken: "tok-rem"
        )

        let url = try #require(captureUrl.value)
        #expect(url.path == "/api/v1/feature-requests/fr-rem-1/vote")
        #expect(captureMethod.value == "DELETE")

        let data = try #require(captureBody.value)
        let dict = try #require(parseJSONDict(data))
        #expect(dict["appKey"] as? String == "app_testkey123456")
        #expect(dict["userToken"] as? String == "tok-rem")

        #expect(result.voted == false)
        #expect(result.voteCount == 14)
    }
}
