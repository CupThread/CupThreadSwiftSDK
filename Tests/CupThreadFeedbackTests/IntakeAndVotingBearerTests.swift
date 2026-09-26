import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Intake and voting bearer authentication contract (#210)

/// Verifies that intake (submit feedback, submit feature request) and voting
/// (toggle vote) endpoints properly attach the user's bearer token when the
/// client is configured with an `authenticationProvider`, and omit the header
/// when the provider returns `nil`/whitespace or is not configured.
@Suite("IntakeAndVotingBearerAuth", .serialized)
struct IntakeAndVotingBearerTests {
    private static let host = "intake-auth.test.example.com"
    private static let baseURL = URL(string: "https://\(host)")!

    private let voteSuccessJSON: [String: Any] = [
        "hasVoted": true,
        "voteCount": 42
    ]

    private let featureRequestSuccessJSON: [String: Any] = [
        "featureRequestId": "fr_test_123",
        "pending": true
    ]

    private let feedbackSuccessJSON: [String: Any] = [
        "submissionId": "sub_test_123",
        "forwardedToGithub": false
    ]

    // MARK: - toggleVote

    @Test func toggleVoteAttachesBearerTokenWhenAuthenticated() async throws {
        let capture = CaptureBox<URLRequest>()
        let json = voteSuccessJSON
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            capture.value = request
            return (makeHTTPResponse(status: 200), try encodeJSON(json))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        let client = makeClient(
            baseURL: Self.baseURL,
            authenticationProvider: { "user-jwt-vote-456" }
        )

        let result = try await client.toggleVote(featureRequestId: "req_1", userToken: "user_vote_1")
        #expect(result.voted == true)
        #expect(result.voteCount == 42)

        let request = try #require(capture.value)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer user-jwt-vote-456")
        #expect(request.value(forHTTPHeaderField: "X-User-Token") == "user_vote_1")
        #expect(request.value(forHTTPHeaderField: "X-Request-Id") != nil)
        #expect(request.value(forHTTPHeaderField: "X-SDK-Version") != nil)
    }

    @Test func toggleVoteOmitsAuthorizationHeaderWhenProviderReturnsNilOrEmpty() async throws {
        let captureNil = CaptureBox<URLRequest>()
        let json = voteSuccessJSON
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            captureNil.value = request
            return (makeHTTPResponse(status: 200), try encodeJSON(json))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        let clientNil = makeClient(
            baseURL: Self.baseURL,
            authenticationProvider: { nil }
        )
        _ = try await clientNil.toggleVote(featureRequestId: "req_1", userToken: "user_vote_nil")
        let requestNil = try #require(captureNil.value)
        #expect(requestNil.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(requestNil.value(forHTTPHeaderField: "X-User-Token") == "user_vote_nil")

        let captureWhitespace = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            captureWhitespace.value = request
            return (makeHTTPResponse(status: 200), try encodeJSON(json))
        }

        let clientWhitespace = makeClient(
            baseURL: Self.baseURL,
            authenticationProvider: { "   \n\t  " }
        )
        _ = try await clientWhitespace.toggleVote(featureRequestId: "req_1", userToken: "user_vote_ws")
        let requestWhitespace = try #require(captureWhitespace.value)
        #expect(requestWhitespace.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(requestWhitespace.value(forHTTPHeaderField: "X-User-Token") == "user_vote_ws")
    }

    @Test func toggleVoteWithoutProviderOmitsAuthorizationHeader() async throws {
        let capture = CaptureBox<URLRequest>()
        let json = voteSuccessJSON
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            capture.value = request
            return (makeHTTPResponse(status: 200), try encodeJSON(json))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        let client = makeClient(baseURL: Self.baseURL)
        #expect(client.supportsAuthentication == false)

        _ = try await client.toggleVote(featureRequestId: "req_1", userToken: "user_vote_anon")
        let request = try #require(capture.value)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "X-User-Token") == "user_vote_anon")
    }

    // MARK: - submitFeatureRequest

    @Test func submitFeatureRequestAttachesBearerTokenWhenAuthenticated() async throws {
        let capture = CaptureBox<URLRequest>()
        let json = featureRequestSuccessJSON
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            capture.value = request
            return (makeHTTPResponse(status: 201), try encodeJSON(json))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        let client = makeClient(
            baseURL: Self.baseURL,
            authenticationProvider: { "user-jwt-fr-789" }
        )

        let draft = FeatureRequestDraft(
            title: "Dark mode support",
            description: "Please add dark mode.",
            requesterName: "Alice"
        )
        let result = try await client.submitFeatureRequest(draft, userToken: "user_fr_1")
        #expect(result.featureRequestId == "fr_test_123")
        #expect(result.pending == true)

        let request = try #require(capture.value)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer user-jwt-fr-789")
        #expect(request.value(forHTTPHeaderField: "X-User-Token") == "user_fr_1")
        #expect(request.value(forHTTPHeaderField: "X-Request-Id") != nil)
        #expect(request.value(forHTTPHeaderField: "X-SDK-Version") != nil)
    }

    @Test func submitFeatureRequestOmitsAuthorizationHeaderWhenProviderReturnsNilOrEmpty() async throws {
        let captureNil = CaptureBox<URLRequest>()
        let json = featureRequestSuccessJSON
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            captureNil.value = request
            return (makeHTTPResponse(status: 201), try encodeJSON(json))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        let clientNil = makeClient(
            baseURL: Self.baseURL,
            authenticationProvider: { nil }
        )
        let draft = FeatureRequestDraft(title: "Title", description: "Desc")
        _ = try await clientNil.submitFeatureRequest(draft, userToken: "user_fr_nil")
        let requestNil = try #require(captureNil.value)
        #expect(requestNil.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(requestNil.value(forHTTPHeaderField: "X-User-Token") == "user_fr_nil")

        let captureWhitespace = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            captureWhitespace.value = request
            return (makeHTTPResponse(status: 201), try encodeJSON(json))
        }

        let clientWhitespace = makeClient(
            baseURL: Self.baseURL,
            authenticationProvider: { "   " }
        )
        _ = try await clientWhitespace.submitFeatureRequest(draft, userToken: "user_fr_ws")
        let requestWhitespace = try #require(captureWhitespace.value)
        #expect(requestWhitespace.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(requestWhitespace.value(forHTTPHeaderField: "X-User-Token") == "user_fr_ws")
    }

    @Test func submitFeatureRequestWithoutProviderOmitsAuthorizationHeader() async throws {
        let capture = CaptureBox<URLRequest>()
        let json = featureRequestSuccessJSON
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            capture.value = request
            return (makeHTTPResponse(status: 201), try encodeJSON(json))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        let client = makeClient(baseURL: Self.baseURL)
        let draft = FeatureRequestDraft(title: "Title", description: "Desc")
        _ = try await client.submitFeatureRequest(draft, userToken: "user_fr_anon")
        let request = try #require(capture.value)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "X-User-Token") == "user_fr_anon")
    }

    // MARK: - submit (feedback)

    @Test func submitFeedbackAttachesBearerTokenWhenAuthenticated() async throws {
        let capture = CaptureBox<URLRequest>()
        let json = feedbackSuccessJSON
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            capture.value = request
            return (makeHTTPResponse(status: 201), try encodeJSON(json))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        let client = makeClient(
            baseURL: Self.baseURL,
            authenticationProvider: { "user-jwt-feedback-321" }
        )

        let draft = FeedbackDraft(title: "Crash on launch", description: "Crashes on iOS 18", platform: .ios)
        let result = try await client.submit(draft, userToken: "user_fb_1")
        #expect(result.submissionId == "sub_test_123")

        let request = try #require(capture.value)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer user-jwt-feedback-321")
        #expect(request.value(forHTTPHeaderField: "X-User-Token") == "user_fb_1")
        #expect(request.value(forHTTPHeaderField: "X-Request-Id") != nil)
        #expect(request.value(forHTTPHeaderField: "X-SDK-Version") != nil)
    }

    @Test func submitFeedbackOmitsAuthorizationHeaderWhenProviderReturnsNilOrEmpty() async throws {
        let captureNil = CaptureBox<URLRequest>()
        let json = feedbackSuccessJSON
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            captureNil.value = request
            return (makeHTTPResponse(status: 201), try encodeJSON(json))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        let clientNil = makeClient(
            baseURL: Self.baseURL,
            authenticationProvider: { nil }
        )
        let draft = FeedbackDraft(title: "Bug", description: "Details", platform: .ios)
        _ = try await clientNil.submit(draft, userToken: "user_fb_nil")
        let requestNil = try #require(captureNil.value)
        #expect(requestNil.value(forHTTPHeaderField: "Authorization") == nil)

        let captureWhitespace = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            captureWhitespace.value = request
            return (makeHTTPResponse(status: 201), try encodeJSON(json))
        }

        let clientWhitespace = makeClient(
            baseURL: Self.baseURL,
            authenticationProvider: { "   \t  " }
        )
        _ = try await clientWhitespace.submit(draft, userToken: "user_fb_ws")
        let requestWhitespace = try #require(captureWhitespace.value)
        #expect(requestWhitespace.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func submitFeedbackWithoutProviderOmitsAuthorizationHeader() async throws {
        let capture = CaptureBox<URLRequest>()
        let json = feedbackSuccessJSON
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            capture.value = request
            return (makeHTTPResponse(status: 201), try encodeJSON(json))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        let client = makeClient(baseURL: Self.baseURL)
        let draft = FeedbackDraft(title: "Bug", description: "Details", platform: .ios)
        _ = try await client.submit(draft, userToken: "user_fb_anon")
        let request = try #require(capture.value)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: - Turnstile retry preserves bearer token

    @Test func turnstileRetryPreservesBearerTokenOnIntakeEndpoints() async throws {
        let requests = CaptureBox<[URLRequest]>()
        let attemptCounter = CaptureBox<Int>()
        attemptCounter.value = 0
        let json = feedbackSuccessJSON

        MockURLProtocol.setHandler(forHost: Self.host) { request in
            var list = requests.value ?? []
            list.append(request)
            requests.value = list
            let current = (attemptCounter.value ?? 0) + 1
            attemptCounter.value = current

            if current == 1 {
                return (
                    makeHTTPResponse(status: 403),
                    try encodeJSON(["code": "turnstile_required", "message": "Verification required"])
                )
            }
            return (makeHTTPResponse(status: 201), try encodeJSON(json))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        let config = FeedbackClientConfiguration(
            baseURL: Self.baseURL,
            appKey: "app_test_turnstile_bearer",
            defaultPlatform: .ios
        )
        let client = FeedbackClient(
            configuration: config,
            session: makeMockSession(),
            turnstileTokenProvider: { "turnstile-token" },
            authenticationProvider: { "user-jwt-retry-token" }
        )

        let draft = FeedbackDraft(title: "Feedback with retry", description: "Details", platform: .ios)
        let result = try await client.submit(draft, userToken: "user_fb_retry")
        #expect(result.submissionId == "sub_test_123")

        let captured = try #require(requests.value)
        #expect(captured.count == 2)
        #expect(captured[0].value(forHTTPHeaderField: "Authorization") == "Bearer user-jwt-retry-token")
        #expect(captured[1].value(forHTTPHeaderField: "Authorization") == "Bearer user-jwt-retry-token")
    }
}
