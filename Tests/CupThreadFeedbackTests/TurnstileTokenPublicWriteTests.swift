import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Turnstile token support on changelog subscribe (#448)

/// Verifies that `subscribeToChangelog` supports the optional `turnstileToken`
/// parameter for Cloudflare Turnstile bot verification on the subscription write:
/// - Tokens ride on the request payload only when supplied.
/// - Whitespace-only values are trimmed and treated as absent (omitted from serialized JSON).
/// - Absent/nil tokens preserve historical payload shape without sending null fields.
/// - Human-verification failures (`turnstile_verification_failed`) surface as typed `.turnstileRequired`.
///
/// The feature-request vote side of this API sync is covered by
/// `TurnstileVotingTests` (landed with the anonymous-vote Turnstile support).
@Suite("TurnstileTokenPublicWrite", .serialized)
struct TurnstileTokenPublicWriteTests {
    private static let host = "turnstile-write.example.com"

    private static func makeAPIClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(host)")!)
    }

    // MARK: - Changelog Subscribe

    @Test func subscribeToChangelogOmitsTurnstileTokenByDefault() async throws {
        let capture = CaptureBox<Data>()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            capture.value = bodyData(from: request)
            return (makeHTTPResponse(status: 201), try encodeJSON(["subscribed": true]))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        let result = try await Self.makeAPIClient().subscribeToChangelog(
            email: "subscriber@example.com",
            userToken: "tok-user-1"
        )
        #expect(result.subscribed == true)

        let data = try #require(capture.value)
        let dict = try #require(parseJSONDict(data))
        #expect(dict["email"] as? String == "subscriber@example.com")
        #expect(dict["turnstileToken"] == nil)
        #expect(dict.count == 1)
    }

    @Test func subscribeToChangelogSendsTurnstileTokenWhenProvided() async throws {
        let capture = CaptureBox<Data>()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            capture.value = bodyData(from: request)
            return (makeHTTPResponse(status: 201), try encodeJSON(["subscribed": true]))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        _ = try await Self.makeAPIClient().subscribeToChangelog(
            email: "subscriber@example.com",
            userToken: "tok-user-1",
            turnstileToken: "cf-turnstile-token-subscribe-12345"
        )

        let data = try #require(capture.value)
        let dict = try #require(parseJSONDict(data))
        #expect(dict["email"] as? String == "subscriber@example.com")
        #expect(dict["turnstileToken"] as? String == "cf-turnstile-token-subscribe-12345")
        #expect(dict.count == 2)
    }

    @Test func subscribeToChangelogTrimsTurnstileToken() async throws {
        let capture = CaptureBox<Data>()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            capture.value = bodyData(from: request)
            return (makeHTTPResponse(status: 201), try encodeJSON(["subscribed": true]))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        _ = try await Self.makeAPIClient().subscribeToChangelog(
            email: "subscriber@example.com",
            userToken: "tok-user-1",
            turnstileToken: "   token-with-whitespace \n\t "
        )

        let data = try #require(capture.value)
        let dict = try #require(parseJSONDict(data))
        #expect(dict["turnstileToken"] as? String == "token-with-whitespace")
    }

    @Test func subscribeToChangelogTreatsWhitespaceOnlyTurnstileTokenAsAbsent() async throws {
        let capture = CaptureBox<Data>()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            capture.value = bodyData(from: request)
            return (makeHTTPResponse(status: 201), try encodeJSON(["subscribed": true]))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        _ = try await Self.makeAPIClient().subscribeToChangelog(
            email: "subscriber@example.com",
            userToken: "tok-user-1",
            turnstileToken: "    \t \n "
        )

        let data = try #require(capture.value)
        let dict = try #require(parseJSONDict(data))
        #expect(dict["turnstileToken"] == nil)
        #expect(dict.count == 1)
    }

    @Test func subscribeToChangelogSurfacesTurnstileRequiredError() async throws {
        MockURLProtocol.setHandler(forHost: Self.host) { _ in
            (
                makeHTTPResponse(status: 403, headers: ["X-Request-Id": "req-turnstile-sub-fail"]),
                try encodeJSON([
                    "code": "turnstile_verification_failed",
                    "error": "Human verification failed. Please try again."
                ])
            )
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        do {
            _ = try await Self.makeAPIClient().subscribeToChangelog(
                email: "bot@example.com",
                userToken: "tok-user-1"
            )
            Issue.record("Expected turnstileRequired error to be thrown")
        } catch let error as FeedbackClientError {
            guard case .turnstileRequired(let message, let requestId) = error else {
                Issue.record("Unexpected error case: \(error)")
                return
            }
            #expect(message == "Human verification failed. Please try again.")
            #expect(requestId == "req-turnstile-sub-fail")
        }
    }

}
