import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Turnstile-gated intake: payload & error mapping (#53, Phase 1)

/// Pins the Turnstile wire contract on the two intake endpoints: the
/// provider's token reaches the body as `turnstileToken` (absent without a
/// provider), and the server's 403 human-verification rejection maps to the
/// typed ``FeedbackClientError/turnstileRequired(message:requestId:)`` case —
/// both the machine-readable code and today's message-only live shape.
@Suite("TurnstileIntake", .serialized)
struct TurnstileIntakeTests {
    static let host = "turnstile.example.com"
    static let baseURL = URL(string: "https://\(host)")!

    let feedbackReceipt = ["submissionId": "s-1", "forwardedToGithub": true] as [String: Any]
    let featureRequestReceipt = ["featureRequestId": "fr-1", "pending": true] as [String: Any]

    // MARK: Helpers

    /// Thread-safe provider stub handing out tokens in order (`nil` entries
    /// included) and counting every consultation.
    final class TokenProvider: @unchecked Sendable {
        private let lock = NSLock()
        private var tokens: [String?]
        private var calls = 0

        init(_ tokens: [String?]) {
            self.tokens = tokens
        }

        func next() -> String? {
            lock.lock()
            defer { lock.unlock() }
            calls += 1
            return tokens.isEmpty ? nil : tokens.removeFirst()
        }

        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }

    /// Thread-safe log of every intercepted request body.
    final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [Data] = []

        func append(_ request: URLRequest) {
            lock.lock()
            defer { lock.unlock() }
            if let data = bodyData(from: request) {
                bodies.append(data)
            }
        }

        var allBodies: [Data] {
            lock.lock()
            defer { lock.unlock() }
            return bodies
        }
    }

    func makeClient(
        turnstileTokenProvider: (@Sendable () async -> String?)? = nil
    ) -> FeedbackClient {
        FeedbackClient(
            configuration: FeedbackClientConfiguration(
                baseURL: Self.baseURL,
                appKey: "app_turnstile1"
            ),
            session: makeMockSession(),
            turnstileTokenProvider: turnstileTokenProvider
        )
    }

    static func turnstileRejection(
        code: String? = nil,
        message: String = "Human verification (Turnstile) is required"
    ) throws -> (HTTPURLResponse, Data) {
        var body: [String: Any] = ["error": message]
        if let code {
            body["code"] = code
        }
        let response = HTTPURLResponse(
            url: URL(string: "https://\(host)/api/v1/feedback")!,
            statusCode: 403,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json", "X-Request-Id": "req-ts-1"]
        )!
        return (response, try encodeJSON(body))
    }

    // MARK: Payload encoding (issue requirement 1)

    @Test func feedbackSubmissionSendsProviderTurnstileToken() async throws {
        let provider = TokenProvider(["tok-1234567890"])
        let log = RequestLog()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            log.append(request)
            return (makeHTTPResponse(status: 200), try encodeJSON(feedbackReceipt))
        }

        let client = makeClient(turnstileTokenProvider: { await provider.next() })
        _ = try await client.submit(FeedbackDraft(title: "Title", description: "Description", platform: .ios))

        let rawBody = try #require(log.allBodies.first)
        let json = try #require(parseJSONDict(rawBody))
        #expect(json["turnstileToken"] as? String == "tok-1234567890")
    }

    @Test func feedbackSubmissionOmitsTurnstileKeyWithoutProvider() async throws {
        let log = RequestLog()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            log.append(request)
            return (makeHTTPResponse(status: 200), try encodeJSON(feedbackReceipt))
        }

        let client = makeClient()
        _ = try await client.submit(FeedbackDraft(title: "Title", description: "Description", platform: .ios))

        let rawBody = try #require(log.allBodies.first)
        let json = try #require(parseJSONDict(rawBody))
        #expect(json.keys.contains("turnstileToken") == false)
    }

    @Test func feedbackSubmissionOmitsTurnstileKeyWhenProviderYieldsNil() async throws {
        let provider = TokenProvider([nil])
        let log = RequestLog()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            log.append(request)
            return (makeHTTPResponse(status: 200), try encodeJSON(feedbackReceipt))
        }

        let client = makeClient(turnstileTokenProvider: { await provider.next() })
        _ = try await client.submit(FeedbackDraft(title: "Title", description: "Description", platform: .ios))

        let rawBody = try #require(log.allBodies.first)
        let json = try #require(parseJSONDict(rawBody))
        #expect(json.keys.contains("turnstileToken") == false)
        #expect(provider.callCount == 1)
    }

    @Test func featureRequestSubmissionSendsProviderTurnstileToken() async throws {
        let provider = TokenProvider(["tok-1234567890"])
        let log = RequestLog()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            log.append(request)
            return (makeHTTPResponse(status: 201), try encodeJSON(featureRequestReceipt))
        }

        let client = makeClient(turnstileTokenProvider: { await provider.next() })
        _ = try await client.submitFeatureRequest(
            FeatureRequestDraft(title: "Title", description: "Description"),
            userToken: "user-1"
        )

        let rawBody = try #require(log.allBodies.first)
        let json = try #require(parseJSONDict(rawBody))
        #expect(json["turnstileToken"] as? String == "tok-1234567890")
        #expect(json["requesterToken"] as? String == "user-1")
    }

    @Test func featureRequestSubmissionOmitsTurnstileKeyWithoutProvider() async throws {
        let log = RequestLog()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            log.append(request)
            return (makeHTTPResponse(status: 201), try encodeJSON(featureRequestReceipt))
        }

        let client = makeClient()
        _ = try await client.submitFeatureRequest(
            FeatureRequestDraft(title: "Title", description: "Description"),
            userToken: "user-1"
        )

        let rawBody = try #require(log.allBodies.first)
        let json = try #require(parseJSONDict(rawBody))
        #expect(json.keys.contains("turnstileToken") == false)
    }

    // MARK: Typed error mapping (issue requirement 2)

    @Test func turnstileCodedRejectionMapsToTypedError() async throws {
        MockURLProtocol.setHandler(forHost: Self.host) { _ in
            try Self.turnstileRejection(code: "turnstile_required")
        }

        let client = makeClient()
        do {
            _ = try await client.submit(FeedbackDraft(title: "Title", description: "Description", platform: .ios))
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            guard case .turnstileRequired(let message, let requestId) = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
            #expect(message == "Human verification (Turnstile) is required")
            #expect(requestId == "req-ts-1")
        }
    }

    @Test func uploadsVerificationCodeMapsToTypedError() async throws {
        // The uploads-sessions route already rejects with the machine-readable
        // code; the shared validateResponse maps it to the same typed case.
        MockURLProtocol.setHandler(forHost: Self.host) { _ in
            try Self.turnstileRejection(code: "turnstile_verification_failed")
        }

        let client = makeClient()
        do {
            _ = try await client.submitFeatureRequest(
                FeatureRequestDraft(title: "Title", description: "Description"),
                userToken: "user-1"
            )
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            guard case .turnstileRequired = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
        }
    }

    @Test func messageOnlyRejectionMapsToTypedError() async throws {
        // Today's live intake shape: 403 with only the human message, no code.
        MockURLProtocol.setHandler(forHost: Self.host) { _ in
            try Self.turnstileRejection()
        }

        let client = makeClient()
        do {
            _ = try await client.submitFeatureRequest(
                FeatureRequestDraft(title: "Title", description: "Description"),
                userToken: "user-1"
            )
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            guard case .turnstileRequired = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
        }
    }

    @Test func other403RejectionMapsToForbidden() async throws {
        MockURLProtocol.setHandler(forHost: Self.host) { _ in
            try Self.turnstileRejection(code: "workspace_forbidden", message: "Not allowed here")
        }

        let client = makeClient()
        do {
            _ = try await client.submit(FeedbackDraft(title: "Title", description: "Description", platform: .ios))
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            // Intake endpoints map permission errors (#34): a 403 that is not
            // a Turnstile rejection is the console forbidding the action.
            guard case .forbidden(let message, _) = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
            #expect(message == "Not allowed here")
        }
    }

    @Test func turnstileRequiredRendersLocalizedCopyWithoutServerText() {
        let error = FeedbackClientError.turnstileRequired(
            message: "Human verification (Turnstile) is required",
            requestId: "req-ts-2"
        )
        #expect(
            error.errorDescription
                == CupThreadStrings.tr("cupthread.error.turnstile_required") + " (request id: req-ts-2)"
        )
        #expect(error.responseBody == nil)
        #expect(error.requestId == "req-ts-2")
        // FriendlyError renders the same localized copy — never the server text.
        #expect(FriendlyError.message(for: error) == error.errorDescription)
    }

    // MARK: Rejection predicate

    @Test func turnstileRejectionPredicateDistinguishesCodes() {
        #expect(FeedbackClient.isTurnstileRejection(code: "turnstile_required", message: nil))
        #expect(FeedbackClient.isTurnstileRejection(code: "turnstile_verification_failed", message: nil))
        #expect(FeedbackClient.isTurnstileRejection(code: nil, message: "Human verification (Turnstile) is required"))
        #expect(FeedbackClient.isTurnstileRejection(code: nil, message: "human verification required"))
        #expect(FeedbackClient.isTurnstileRejection(code: nil, message: "TURNSTILE token missing"))
        // A present non-turnstile code wins over the message.
        #expect(!FeedbackClient.isTurnstileRejection(code: "workspace_forbidden", message: "Turnstile gone"))
        #expect(!FeedbackClient.isTurnstileRejection(code: nil, message: "Not allowed here"))
        #expect(!FeedbackClient.isTurnstileRejection(code: nil, message: nil))
    }
}
