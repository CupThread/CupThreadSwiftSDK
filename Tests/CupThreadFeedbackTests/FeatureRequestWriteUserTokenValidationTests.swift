import Foundation
import Testing
@testable import CupThreadFeedback

// Regression tests for #493: the three write endpoints that carry an
// anonymous end-user identity — castVote, removeVote, and
// submitFeatureRequest — must reject a blank, whitespace-only, or
// newline-bearing userToken locally (applyUserToken would silently drop the
// `X-User-Token` header while the raw value still rode in the JSON body, and
// the Turnstile-gated calls would mint a single-use challenge token for a
// request that cannot succeed), and must send a valid token trimmed once,
// identically in the body and the header. Lives in its own suite (and host)
// so it can run in parallel with the other validation suites.
@Suite("FeatureRequestWriteUserTokenValidation", .serialized)
struct WriteUserTokenValidationTests {
    static let apiHost = "feature-write-token-validation.example.com"
    static let paddedToken = "  6bd3ff2e-9c31-4f18-a5ce-2f4d8ba1c7d9  "
    static let trimmedToken = "6bd3ff2e-9c31-4f18-a5ce-2f4d8ba1c7d9"

    final class ProviderCounter: @unchecked Sendable {
        var mintedAny = false
    }

    static func makeValidatedClient(
        providerCalls: ProviderCounter? = nil
    ) -> FeedbackClient {
        let provider: (@Sendable (TurnstileChallenge) async -> String?)?
        if let providerCalls {
            provider = { _ in
                providerCalls.mintedAny = true
                return "provider-minted-token"
            }
        } else {
            provider = nil
        }
        return FeedbackClient(
            configuration: FeedbackClientConfiguration(
                baseURL: URL(string: "https://\(apiHost)")!,
                appKey: "app_testkey123456"
            ),
            session: makeMockSession(),
            turnstileTokenProvider: provider
        )
    }

    static func stubVoteResponse(_ capture: CaptureBox<URLRequest>) {
        MockURLProtocol.setHandler(forHost: apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["voted": true, "voteCount": 7]))
        }
    }

    static func stubSubmitResponse(_ capture: CaptureBox<URLRequest>) {
        MockURLProtocol.setHandler(forHost: apiHost) { request in
            capture.value = request
            return (
                makeHTTPResponse(status: 201),
                try encodeJSON(["featureRequestId": "fr-new-493", "pending": true])
            )
        }
    }

    static func clearHostHandler() {
        MockURLProtocol.setHandler(forHost: apiHost, nil)
    }

    // MARK: - castVote local rejection

    @Test func castVoteRejectsBlankUserTokenWithoutNetworkOrTurnstileMint() async {
        let capture = CaptureBox<URLRequest>()
        let providerCalls = ProviderCounter()
        Self.stubVoteResponse(capture)
        defer { Self.clearHostHandler() }

        for blankToken in ["", "   ", "\n", " \n\t "] {
            await #expect(throws: FeedbackClientError.authenticationRequired) {
                try await Self.makeValidatedClient(providerCalls: providerCalls).castVote(
                    featureRequestId: "fr-write-1",
                    userToken: blankToken
                )
            }
        }

        #expect(capture.value == nil, "no network request may be built for a blank token")
        #expect(!providerCalls.mintedAny, "the Turnstile provider must not be consulted for a doomed request")
    }

    @Test func castVoteRejectsNewlineBearingUserTokenWithoutNetwork() async {
        let capture = CaptureBox<URLRequest>()
        let providerCalls = ProviderCounter()
        Self.stubVoteResponse(capture)
        defer { Self.clearHostHandler() }

        for multiLineToken in ["tok\n123", "tok\r\n123", "tok\r\nInjected: evil", "abc\ndef"] {
            await #expect(throws: FeedbackClientError.authenticationRequired) {
                try await Self.makeValidatedClient(providerCalls: providerCalls).castVote(
                    featureRequestId: "fr-write-2",
                    userToken: multiLineToken
                )
            }
        }

        #expect(capture.value == nil, "no network request may be built for a multi-line token")
        #expect(!providerCalls.mintedAny)
    }

    // MARK: - removeVote local rejection

    @Test func removeVoteRejectsBlankUserTokenWithoutNetwork() async {
        let capture = CaptureBox<URLRequest>()
        Self.stubVoteResponse(capture)
        defer { Self.clearHostHandler() }

        for blankToken in ["", "   ", "\n", " \n\t "] {
            await #expect(throws: FeedbackClientError.authenticationRequired) {
                try await Self.makeValidatedClient().removeVote(
                    featureRequestId: "fr-write-3",
                    userToken: blankToken
                )
            }
        }

        #expect(capture.value == nil, "no network request may be built for a blank token")
    }

    @Test func removeVoteRejectsNewlineBearingUserTokenWithoutNetwork() async {
        let capture = CaptureBox<URLRequest>()
        Self.stubVoteResponse(capture)
        defer { Self.clearHostHandler() }

        for multiLineToken in ["tok\n123", "tok\r\n123", "tok\r\nInjected: evil", "abc\ndef"] {
            await #expect(throws: FeedbackClientError.authenticationRequired) {
                try await Self.makeValidatedClient().removeVote(
                    featureRequestId: "fr-write-4",
                    userToken: multiLineToken
                )
            }
        }

        #expect(capture.value == nil, "no network request may be built for a multi-line token")
    }

    // MARK: - submitFeatureRequest local rejection

    @Test func submitFeatureRequestRejectsBlankUserTokenWithoutNetworkOrTurnstileMint() async {
        let capture = CaptureBox<URLRequest>()
        let providerCalls = ProviderCounter()
        Self.stubSubmitResponse(capture)
        defer { Self.clearHostHandler() }

        for blankToken in ["", "   ", "\n", " \n\t "] {
            await #expect(throws: FeedbackClientError.authenticationRequired) {
                try await Self.makeValidatedClient(providerCalls: providerCalls).submitFeatureRequest(
                    FeatureRequestDraft(title: "Dark mode", description: "Please add dark mode"),
                    userToken: blankToken
                )
            }
        }

        #expect(capture.value == nil, "no network request may be built for a blank token")
        #expect(!providerCalls.mintedAny, "the Turnstile provider must not be consulted for a doomed request")
    }

    @Test func submitFeatureRequestRejectsNewlineBearingUserTokenWithoutNetwork() async {
        let capture = CaptureBox<URLRequest>()
        let providerCalls = ProviderCounter()
        Self.stubSubmitResponse(capture)
        defer { Self.clearHostHandler() }

        for multiLineToken in ["tok\n123", "tok\r\n123", "tok\r\nInjected: evil", "abc\ndef"] {
            await #expect(throws: FeedbackClientError.authenticationRequired) {
                try await Self.makeValidatedClient(providerCalls: providerCalls).submitFeatureRequest(
                    FeatureRequestDraft(title: "Dark mode", description: "Please add dark mode"),
                    userToken: multiLineToken
                )
            }
        }

        #expect(capture.value == nil, "no network request may be built for a multi-line token")
        #expect(!providerCalls.mintedAny)
    }

    // MARK: - Trimmed token agreement between body and header

    @Test func castVoteSendsTrimmedTokenIdenticallyInBodyAndHeader() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubVoteResponse(capture)
        defer { Self.clearHostHandler() }

        _ = try await Self.makeValidatedClient().castVote(
            featureRequestId: "fr-write-trim-1",
            userToken: Self.paddedToken
        )

        let request = try #require(capture.value)
        #expect(request.value(forHTTPHeaderField: "X-User-Token") == Self.trimmedToken)
        let data = try #require(bodyData(from: request))
        let dict = try #require(parseJSONDict(data))
        #expect(dict["userToken"] as? String == Self.trimmedToken)
    }

    @Test func removeVoteSendsTrimmedTokenIdenticallyInBodyAndHeader() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubVoteResponse(capture)
        defer { Self.clearHostHandler() }

        _ = try await Self.makeValidatedClient().removeVote(
            featureRequestId: "fr-write-trim-2",
            userToken: Self.paddedToken
        )

        let request = try #require(capture.value)
        #expect(request.value(forHTTPHeaderField: "X-User-Token") == Self.trimmedToken)
        let data = try #require(bodyData(from: request))
        let dict = try #require(parseJSONDict(data))
        #expect(dict["userToken"] as? String == Self.trimmedToken)
    }

    @Test func submitFeatureRequestSendsTrimmedTokenIdenticallyInBodyAndHeader() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubSubmitResponse(capture)
        defer { Self.clearHostHandler() }

        _ = try await Self.makeValidatedClient().submitFeatureRequest(
            FeatureRequestDraft(title: "Dark mode", description: "Please add dark mode"),
            userToken: Self.paddedToken
        )

        let request = try #require(capture.value)
        #expect(request.value(forHTTPHeaderField: "X-User-Token") == Self.trimmedToken)
        let data = try #require(bodyData(from: request))
        let dict = try #require(parseJSONDict(data))
        #expect(dict["requesterToken"] as? String == Self.trimmedToken)
    }
}
