import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Turnstile provider binding (API-15, SaaS #543)

/// Pins the `(action, cdata)` widget binding the SDK asks the Turnstile token
/// provider for on every gated intake call: `feedback` for feedback
/// submission and upload-session creation (including the `uploadAttachment`
/// convenience wrappers), `feature-request` for feature-request submission —
/// `cdata` always the app key — and the same binding again on the automatic
/// single retry. A regression that consults the provider without context or
/// under the wrong action fails here.
@Suite("TurnstileChallenge", .serialized)
struct TurnstileChallengeTests {
    static let host = "turnstile-challenge.example.com"
    static let baseURL = URL(string: "https://\(host)")!
    static let appKey = "app_challenge1"

    // MARK: Helpers

    /// Thread-safe provider recording every consultation's binding and
    /// handing out tokens in order (`nil` entries included).
    final class RecordingProvider: @unchecked Sendable {
        private let lock = NSLock()
        private var challenges: [TurnstileChallenge] = []
        private var tokens: [String?]
        private var calls = 0

        init(_ tokens: [String?]) {
            self.tokens = tokens
        }

        func token(for challenge: TurnstileChallenge) -> String? {
            lock.lock()
            defer { lock.unlock() }
            challenges.append(challenge)
            guard calls < tokens.count else { return nil }
            defer { calls += 1 }
            return tokens[calls]
        }

        var recordedChallenges: [TurnstileChallenge] {
            lock.lock()
            defer { lock.unlock() }
            return challenges
        }
    }

    func makeClient(provider: RecordingProvider) -> FeedbackClient {
        FeedbackClient(
            configuration: FeedbackClientConfiguration(
                baseURL: Self.baseURL,
                appKey: Self.appKey
            ),
            session: makeMockSession(),
            turnstileTokenProvider: { challenge in provider.token(for: challenge) }
        )
    }

    static func turnstileRejection() throws -> (HTTPURLResponse, Data) {
        (
            makeHTTPResponse(status: 403, headers: ["X-Request-Id": "req-ch-1"]),
            try encodeJSON(["error": "Human verification (Turnstile) is required"])
        )
    }

    static func uploadSessionJSON() throws -> Data {
        try encodeJSON([
            "session": [
                "sessionId": "sess-ch-1",
                "sessionToken": "stok-ch",
                "expiresAt": NSNull(),
                "maxFileSizeBytes": NSNull(),
                "maxFiles": NSNull()
            ],
            "files": [[
                "clientFileId": "file-1",
                "uploadId": "upl-ch-1",
                "uploadUrl": "https://\(host)/api/v1/uploads/upl-ch-1",
                "maxSizeBytes": NSNull()
            ]]
        ])
    }

    // MARK: Server-aligned constants

    @Test func actionConstantsMatchServerBindings() {
        #expect(TurnstileAction.feedback == "feedback")
        #expect(TurnstileAction.featureRequest == "feature-request")
        #expect(
            TurnstileChallenge.feedback(appKey: "app_x")
                == TurnstileChallenge(action: "feedback", cdata: "app_x")
        )
        #expect(
            TurnstileChallenge.featureRequest(appKey: "app_x")
                == TurnstileChallenge(action: "feature-request", cdata: "app_x")
        )
    }

    // MARK: Feedback submission binding (first attempt + retry)

    @Test func submitConsultsProviderWithFeedbackBindingOnFirstAttemptAndRetry() async throws {
        let provider = RecordingProvider(["tok-feedback-attempt1", "tok-feedback-retry"])
        MockURLProtocol.setHandler(forHost: Self.host) { _ in
            // The first minted token is unbound in this scenario, so the gate
            // rejects attempt one and the SDK retries with a fresh token.
            if provider.recordedChallenges.count == 1 {
                return try Self.turnstileRejection()
            }
            return (makeHTTPResponse(status: 200), try encodeJSON(["submissionId": "s-1"]))
        }

        let client = makeClient(provider: provider)
        _ = try await client.submit(
            FeedbackDraft(title: "Title", description: "Description", platform: .ios)
        )

        // Both consultations — the first attempt and the single retry — are
        // bound to the feedback action and the app key.
        let expected = TurnstileChallenge.feedback(appKey: Self.appKey)
        #expect(provider.recordedChallenges == [expected, expected])
    }

    @Test func submitWithoutRejectionConsultsProviderExactlyOnceWithFeedbackBinding() async throws {
        let provider = RecordingProvider(["tok-feedback-only"])
        MockURLProtocol.setHandler(forHost: Self.host) { _ in
            (makeHTTPResponse(status: 200), try encodeJSON(["submissionId": "s-1"]))
        }

        let client = makeClient(provider: provider)
        _ = try await client.submit(
            FeedbackDraft(title: "Title", description: "Description", platform: .ios)
        )

        #expect(provider.recordedChallenges == [.feedback(appKey: Self.appKey)])
    }

    // MARK: Feature-request submission binding

    @Test func submitFeatureRequestConsultsProviderWithFeatureRequestBinding() async throws {
        let provider = RecordingProvider(["tok-fr-00000001"])
        MockURLProtocol.setHandler(forHost: Self.host) { _ in
            (
                makeHTTPResponse(status: 201),
                try encodeJSON(["featureRequestId": "fr-1", "pending": true])
            )
        }

        let client = makeClient(provider: provider)
        _ = try await client.submitFeatureRequest(
            FeatureRequestDraft(title: "Title", description: "Description"),
            userToken: "user-1"
        )

        // A feedback-bound consultation (the pre-binding context-free shape)
        // fails this exact-match assertion.
        #expect(provider.recordedChallenges == [.featureRequest(appKey: Self.appKey)])
    }

    // MARK: Upload-session binding (direct + convenience wrappers)

    @Test func createUploadSessionConsultsProviderWithFeedbackBinding() async throws {
        let provider = RecordingProvider(["tok-upload-000001"])
        MockURLProtocol.setHandler(forHost: Self.host) { _ in
            (makeHTTPResponse(status: 201), try Self.uploadSessionJSON())
        }

        let client = makeClient(provider: provider)
        _ = try await client.createUploadSession(
            files: [FeedbackUploadFileSpec(
                clientFileId: "file-1",
                filename: "f.png",
                contentType: "image/png",
                sizeBytes: 5
            )],
            userToken: "user-1"
        )

        // Upload sessions deliberately reuse the feedback action, not a
        // separate "upload" action.
        #expect(provider.recordedChallenges == [.feedback(appKey: Self.appKey)])
    }

    @Test func uploadAttachmentConvenienceConsultsProviderWithFeedbackBinding() async throws {
        let provider = RecordingProvider(["tok-upload-000002"])
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            if request.url?.path.contains("/api/v1/uploads/sessions") == true {
                return (makeHTTPResponse(status: 201), try Self.uploadSessionJSON())
            }
            // The slot PUT accepts an empty lenient body; only the session
            // creation consults the provider.
            return (makeHTTPResponse(status: 200), Data())
        }

        let client = makeClient(provider: provider)
        _ = try await client.uploadAttachment(
            data: Data("hello".utf8),
            filename: "f.png",
            mimeType: "image/png",
            userToken: "user-1"
        )

        #expect(provider.recordedChallenges == [.feedback(appKey: Self.appKey)])
    }
}
