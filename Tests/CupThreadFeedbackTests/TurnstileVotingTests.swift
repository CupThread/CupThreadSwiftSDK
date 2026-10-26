import Foundation
import Testing
@testable import CupThreadFeedback

@Suite("TurnstileVotingTests", .serialized)
struct TurnstileVotingTests {
    static let host = "vote-turnstile.example.com"
    static let baseURL = URL(string: "https://\(host)")!

    static func makeAPIClient(
        tokenProvider: (@Sendable (TurnstileChallenge) async -> String?)? = nil
    ) -> FeedbackClient {
        FeedbackClient(
            configuration: FeedbackClientConfiguration(
                baseURL: baseURL,
                appKey: "app_testkey123456"
            ),
            session: makeMockSession(),
            turnstileTokenProvider: tokenProvider
        )
    }

    // MARK: - Challenge & Action Constants

    @Test func turnstileActionAndChallengeConstantsMatchServer() {
        #expect(TurnstileAction.vote == "vote")
        let challenge = TurnstileChallenge.vote(appKey: "app_key_123")
        #expect(challenge.action == "vote")
        #expect(challenge.cdata == "app_key_123")
    }

    @Test func shipNotifyActionAndChallengeConstantsMatchServer() {
        // SEC-90 (SaaS #983/#1023): the ship-notify opt-in binding.
        #expect(TurnstileAction.shipNotify == "ship-notify")
        let challenge = TurnstileChallenge.shipNotify(appKey: "app_key_123")
        #expect(challenge.action == "ship-notify")
        #expect(challenge.cdata == "app_key_123")
    }

    // MARK: - Vote Payload Shape & Token Handling

    @Test func castVoteOmitsTurnstileTokenByDefault() async throws {
        let capture = CaptureBox<Data>()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            capture.value = bodyData(from: request)
            return (makeHTTPResponse(status: 200), try encodeJSON(["voted": true, "voteCount": 10]))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        let result = try await Self.makeAPIClient().castVote(
            featureRequestId: "fr-vote-1",
            userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f"
        )
        #expect(result.voted == true)

        let data = try #require(capture.value)
        let dict = try #require(parseJSONDict(data))
        #expect(dict["appKey"] as? String == "app_testkey123456")
        #expect(dict["userToken"] as? String == "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f")
        #expect(dict["shipNotifyEmail"] == nil)
        #expect(dict["turnstileToken"] == nil)
        #expect(dict.count == 2)
    }

    @Test func castVoteSendsTurnstileTokenWhenProvided() async throws {
        let capture = CaptureBox<Data>()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            capture.value = bodyData(from: request)
            return (makeHTTPResponse(status: 200), try encodeJSON(["voted": true, "voteCount": 11]))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        _ = try await Self.makeAPIClient().castVote(
            featureRequestId: "fr-vote-1",
            userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f",
            shipNotifyEmail: "voter@example.com",
            turnstileToken: "cf-turnstile-token-vote-12345"
        )

        let data = try #require(capture.value)
        let dict = try #require(parseJSONDict(data))
        #expect(dict["appKey"] as? String == "app_testkey123456")
        #expect(dict["userToken"] as? String == "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f")
        #expect(dict["shipNotifyEmail"] as? String == "voter@example.com")
        #expect(dict["turnstileToken"] as? String == "cf-turnstile-token-vote-12345")
        #expect(dict.count == 4)
    }

    @Test func castVoteTrimsTurnstileToken() async throws {
        let capture = CaptureBox<Data>()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            capture.value = bodyData(from: request)
            return (makeHTTPResponse(status: 200), try encodeJSON(["voted": true, "voteCount": 11]))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        _ = try await Self.makeAPIClient().castVote(
            featureRequestId: "fr-vote-1",
            userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f",
            turnstileToken: "   padded-vote-token   \n"
        )

        let data = try #require(capture.value)
        let dict = try #require(parseJSONDict(data))
        #expect(dict["turnstileToken"] as? String == "padded-vote-token")
    }

    @Test func castVoteTreatsWhitespaceOnlyTurnstileTokenAsAbsent() async throws {
        let capture = CaptureBox<Data>()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            capture.value = bodyData(from: request)
            return (makeHTTPResponse(status: 200), try encodeJSON(["voted": true, "voteCount": 11]))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        _ = try await Self.makeAPIClient().castVote(
            featureRequestId: "fr-vote-1",
            userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f",
            turnstileToken: "   \t\n  "
        )

        let data = try #require(capture.value)
        let dict = try #require(parseJSONDict(data))
        #expect(dict["turnstileToken"] == nil)
        #expect(dict.count == 2)
    }

    // MARK: - Turnstile Provider Integration

    @Test func castVoteResolvesTokenFromProviderWhenAvailable() async throws {
        let capture = CaptureBox<Data>()
        let challengeCapture = CaptureBox<TurnstileChallenge>()

        MockURLProtocol.setHandler(forHost: Self.host) { request in
            capture.value = bodyData(from: request)
            return (makeHTTPResponse(status: 200), try encodeJSON(["voted": true, "voteCount": 12]))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        let client = Self.makeAPIClient { challenge in
            challengeCapture.value = challenge
            return "provider-minted-token"
        }

        _ = try await client.castVote(
            featureRequestId: "fr-vote-provider",
            userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f"
        )

        let challenge = try #require(challengeCapture.value)
        #expect(challenge.action == TurnstileAction.vote)
        #expect(challenge.cdata == "app_testkey123456")

        let data = try #require(capture.value)
        let dict = try #require(parseJSONDict(data))
        #expect(dict["turnstileToken"] as? String == "provider-minted-token")
    }

    @Test func castVoteConsultsProviderWithShipNotifyBindingWhenOptInPresent() async throws {
        // SEC-90: with a `shipNotifyEmail` opt-in the SDK must request the
        // `ship-notify` binding — the only action the ship-notify challenge
        // accepts on boards without anonymous-vote Turnstile, and one of the
        // two accepted on the combined intake.
        let capture = CaptureBox<Data>()
        let challengeCapture = CaptureBox<TurnstileChallenge>()

        MockURLProtocol.setHandler(forHost: Self.host) { request in
            capture.value = bodyData(from: request)
            return (makeHTTPResponse(status: 200), try encodeJSON(["voted": true, "voteCount": 13]))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        let client = Self.makeAPIClient { challenge in
            challengeCapture.value = challenge
            return "ship-notify-minted-token"
        }

        let result = try await client.castVote(
            featureRequestId: "fr-vote-ship-notify",
            userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f",
            shipNotifyEmail: "voter@example.com"
        )
        #expect(result.voted == true)

        let challenge = try #require(challengeCapture.value)
        #expect(challenge.action == TurnstileAction.shipNotify)
        #expect(challenge.action == "ship-notify")
        #expect(challenge.cdata == "app_testkey123456")

        let data = try #require(capture.value)
        let dict = try #require(parseJSONDict(data))
        #expect(dict["shipNotifyEmail"] as? String == "voter@example.com")
        #expect(dict["turnstileToken"] as? String == "ship-notify-minted-token")
    }

    @Test func castVoteRetryWithOptInConsultsProviderUnderShipNotifyBinding() async throws {
        // SEC-90: an explicit token rides the first attempt unchanged; when
        // the gate rejects it, the provider retry must be consulted under the
        // ship-notify binding (accepted by both the combined intake and the
        // Turnstile-off opt-in challenge).
        final class AttemptState: @unchecked Sendable {
            var attempt = 0
        }
        let state = AttemptState()
        let challengeCapture = CaptureBox<TurnstileChallenge>()

        MockURLProtocol.setHandler(forHost: Self.host) { _ in
            state.attempt += 1
            if state.attempt == 1 {
                return (
                    makeHTTPResponse(status: 403, headers: ["X-Request-Id": "req-ship-retry-1"]),
                    try encodeJSON([
                        "code": "turnstile_verification_failed",
                        "error": "Human verification failed."
                    ])
                )
            }
            return (
                makeHTTPResponse(status: 200, headers: ["X-Request-Id": "req-ship-retry-2"]),
                try encodeJSON(["voted": true, "voteCount": 21])
            )
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        let client = Self.makeAPIClient { challenge in
            challengeCapture.value = challenge
            return "retry-ship-notify-token"
        }

        let result = try await client.castVote(
            featureRequestId: "fr-ship-retry",
            userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f",
            shipNotifyEmail: "voter@example.com",
            turnstileToken: "stale-explicit-token"
        )
        #expect(result.voted == true)
        #expect(state.attempt == 2)

        let challenge = try #require(challengeCapture.value)
        #expect(challenge.action == TurnstileAction.shipNotify)
        #expect(challenge.cdata == "app_testkey123456")
    }

    @Test func castVoteSurfacesTurnstileRequiredErrorWhenMissingOrFailed() async throws {
        MockURLProtocol.setHandler(forHost: Self.host) { _ in
            (
                makeHTTPResponse(status: 403, headers: ["X-Request-Id": "req-turnstile-fail"]),
                try encodeJSON([
                    "code": "turnstile_verification_failed",
                    "error": "Human verification failed. Please try again."
                ])
            )
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        do {
            _ = try await Self.makeAPIClient().castVote(
                featureRequestId: "fr-vote-anon",
                userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f"
            )
            Issue.record("Expected turnstileRequired error to be thrown")
        } catch let error as FeedbackClientError {
            guard case .turnstileRequired(let message, let requestId) = error else {
                Issue.record("Unexpected error case: \(error)")
                return
            }
            #expect(message == "Human verification failed. Please try again.")
            #expect(requestId == "req-turnstile-fail")
        }
    }

    @Test func castVoteRetriesOnTurnstileRejectionWhenProviderConfigured() async throws {
        final class ProviderState: @unchecked Sendable {
            var attempt = 0
        }
        let state = ProviderState()
        let capturedTokens = CaptureBox<[String]>()
        capturedTokens.value = []

        MockURLProtocol.setHandler(forHost: Self.host) { request in
            if let data = bodyData(from: request),
               let dict = parseJSONDict(data),
               let token = dict["turnstileToken"] as? String {
                capturedTokens.value?.append(token)
            }
            state.attempt += 1
            if state.attempt == 1 {
                return (
                    makeHTTPResponse(status: 403, headers: ["X-Request-Id": "req-retry-1"]),
                    try encodeJSON([
                        "code": "turnstile_verification_failed",
                        "error": "Human verification failed."
                    ])
                )
            } else {
                return (
                    makeHTTPResponse(status: 200, headers: ["X-Request-Id": "req-retry-2"]),
                    try encodeJSON(["voted": true, "voteCount": 20])
                )
            }
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        final class ProviderCounter: @unchecked Sendable {
            var count = 0
        }
        let counter = ProviderCounter()

        let client = Self.makeAPIClient { challenge in
            #expect(challenge.action == TurnstileAction.vote)
            counter.count += 1
            return "token-attempt-\(counter.count)"
        }

        let result = try await client.castVote(
            featureRequestId: "fr-retry",
            userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f"
        )
        #expect(result.voted == true)
        #expect(result.voteCount == 20)
        #expect(state.attempt == 2)
        #expect(capturedTokens.value == ["token-attempt-1", "token-attempt-2"])
    }

    // MARK: - Legacy toggleVote & removeVote

    @Test func toggleVoteSendsTurnstileTokenWhenProvided() async throws {
        let capture = CaptureBox<Data>()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            capture.value = bodyData(from: request)
            return (makeHTTPResponse(status: 200), try encodeJSON(["voted": true, "voteCount": 12]))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        _ = try await Self.makeAPIClient().toggleVote(
            featureRequestId: "fr-vote-legacy",
            userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f",
            shipNotifyEmail: "legacy@example.com",
            turnstileToken: "token-via-toggle"
        )

        let data = try #require(capture.value)
        let dict = try #require(parseJSONDict(data))
        #expect(dict["turnstileToken"] as? String == "token-via-toggle")
        #expect(dict["shipNotifyEmail"] as? String == "legacy@example.com")
    }

    @Test func removeVoteNeverSendsTurnstileToken() async throws {
        let capture = CaptureBox<Data>()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            capture.value = bodyData(from: request)
            return (makeHTTPResponse(status: 200), try encodeJSON(["voted": false, "voteCount": 9]))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        let client = Self.makeAPIClient { _ in
            Issue.record("Provider should not be consulted for removeVote")
            return "unexpected-token"
        }

        _ = try await client.removeVote(
            featureRequestId: "fr-vote-1",
            userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f"
        )

        let data = try #require(capture.value)
        let dict = try #require(parseJSONDict(data))
        #expect(dict["turnstileToken"] == nil)
        #expect(dict["shipNotifyEmail"] == nil)
        #expect(dict.count == 2)
    }
}
