import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - X-User-Token contract sync (#407, SaaS#837)

/// Pins the corrected write contract from SaaS#837: the anonymous end-user
/// token is read from the JSON body field or the `X-User-Token` header (the
/// body field wins when both are present), the vote `DELETE` requires a JSON
/// body carrying `appKey`, and the hand-written payload/response models match
/// the corrected OpenAPI components — the removal body encodes exactly
/// `{appKey, userToken}`, the propose body never carries a `requesterEmail`
/// field, and `VoteResult` decodes the corrected `VoteResponse` shape.
@Suite("UserTokenContractSync", .serialized)
struct UserTokenContractSyncTests {
    private static let host = "tokcontract.example.com"

    private static func makeAPIClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(host)")!)
    }

    @Test func removeVoteBodyEncodesExactlyAppKeyAndUserToken() async throws {
        let capture = CaptureBox<Data>()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            capture.value = bodyData(from: request)
            return (makeHTTPResponse(status: 200), try encodeJSON(["voted": false, "voteCount": 4]))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        let result = try await Self.makeAPIClient().removeVote(
            featureRequestId: "fr-rem-1",
            userToken: "tok-rem-1"
        )
        #expect(result.voted == false)

        // The corrected DELETE component declares exactly {appKey, userToken};
        // the shared vote payload's always-null shipNotifyEmail/turnstileToken
        // keys must not leak into the removal body.
        let data = try #require(capture.value)
        let dict = try #require(parseJSONDict(data))
        #expect(Set(dict.keys) == ["appKey", "userToken"])
        #expect(dict["appKey"] as? String == "app_testkey123456")
        #expect(dict["userToken"] as? String == "tok-rem-1")
    }

    @Test func castVoteBodyOmitsOptionalFieldsWhenAbsent() async throws {
        let capture = CaptureBox<Data>()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            capture.value = bodyData(from: request)
            return (makeHTTPResponse(status: 200), try encodeJSON(["voted": true, "voteCount": 5]))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        _ = try await Self.makeAPIClient().castVote(
            featureRequestId: "fr-cast-1",
            userToken: "tok-cast-1"
        )

        let data = try #require(capture.value)
        let dict = try #require(parseJSONDict(data))
        #expect(Set(dict.keys) == ["appKey", "userToken"])
    }

    @Test func castVoteBodyIncludesOptionalFieldsOnlyWhenProvided() async throws {
        let capture = CaptureBox<Data>()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            capture.value = bodyData(from: request)
            return (makeHTTPResponse(status: 200), try encodeJSON(["voted": true, "voteCount": 6]))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        _ = try await Self.makeAPIClient().castVote(
            featureRequestId: "fr-cast-2",
            userToken: "tok-cast-2",
            shipNotifyEmail: "voter@example.com",
            turnstileToken: String(repeating: "t", count: 16)
        )

        let data = try #require(capture.value)
        let dict = try #require(parseJSONDict(data))
        #expect(Set(dict.keys) == ["appKey", "userToken", "shipNotifyEmail", "turnstileToken"])
        #expect(dict["shipNotifyEmail"] as? String == "voter@example.com")
        #expect(dict["turnstileToken"] as? String == String(repeating: "t", count: 16))
    }

    @Test func submitFeatureRequestBodyMatchesCorrectedCreateFeatureRequestInput() async throws {
        let capture = CaptureBox<Data>()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            capture.value = bodyData(from: request)
            return (
                makeHTTPResponse(status: 201),
                try encodeJSON(["featureRequestId": "fr-new-1", "pending": true])
            )
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        _ = try await Self.makeAPIClient().submitFeatureRequest(
            FeatureRequestDraft(title: "Dark mode", description: "Please", requesterName: "Ada"),
            userToken: "tok-propose-1"
        )

        // Corrected component: required appKey/title/description, optional
        // requesterName/requesterToken/turnstileToken, and no requesterEmail.
        let data = try #require(capture.value)
        let dict = try #require(parseJSONDict(data))
        #expect(Set(dict.keys) == ["appKey", "title", "description", "requesterName", "requesterToken"])
        #expect(dict["requesterToken"] as? String == "tok-propose-1")
        #expect(dict["requesterName"] as? String == "Ada")
        #expect(dict["requesterEmail"] == nil)

        let anonymous = CaptureBox<Data>()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            anonymous.value = bodyData(from: request)
            return (
                makeHTTPResponse(status: 201),
                try encodeJSON(["featureRequestId": "fr-new-2", "pending": true])
            )
        }
        _ = try await Self.makeAPIClient().submitFeatureRequest(
            FeatureRequestDraft(title: "Dark mode", description: "Please"),
            userToken: "tok-propose-2"
        )
        let anonymousData = try #require(anonymous.value)
        let anonymousDict = try #require(parseJSONDict(anonymousData))
        #expect(Set(anonymousDict.keys) == ["appKey", "title", "description", "requesterToken"])
    }

    @Test func submitFeatureRequestSendsUserTokenHeaderAlongsideBody() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            capture.value = request
            return (
                makeHTTPResponse(status: 201),
                try encodeJSON(["featureRequestId": "fr-new-3", "pending": true])
            )
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        _ = try await Self.makeAPIClient().submitFeatureRequest(
            FeatureRequestDraft(title: "Dark mode", description: "Please"),
            userToken: "tok-propose-3"
        )

        // The header transport stays attached for servers that only read the
        // header; the body field wins when both are present, and the SDK
        // always sends the same token in both.
        #expect(try #require(capture.value).value(forHTTPHeaderField: "X-User-Token") == "tok-propose-3")
    }

    @Test func voteResultDecodesCorrectedVoteResponseComponent() throws {
        // Corrected VoteResponse: voted + voteCount required, warning
        // optional, and none of the removed hasVoted/featureRequestId fields.
        let corrected = try JSONDecoder().decode(VoteResult.self, from: Data("""
        {"voted": true, "voteCount": 12, "warning": {"code": "email_not_verified", "error": "Not verified"}}
        """.utf8))
        #expect(corrected.voted == true)
        #expect(corrected.voteCount == 12)
        #expect(corrected.warning?.isEmailNotVerified == true)

        let minimal = try JSONDecoder().decode(VoteResult.self, from: Data("""
        {"voted": false, "voteCount": 0}
        """.utf8))
        #expect(minimal.voted == false)
        #expect(minimal.voteCount == 0)
        #expect(minimal.warning == nil)
    }
}
