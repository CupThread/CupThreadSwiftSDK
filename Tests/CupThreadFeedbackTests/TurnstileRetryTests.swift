import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Turnstile-gated intake: single retry & upload fallback (#53, Phase 1)

/// Pins the retry semantics of a Turnstile-blocked submission: exactly one
/// automatic retry with a freshly provided token, no retry without a
/// provider (or when the provider yields nothing), and the provider
/// fallback on upload-session creation.
@Suite("TurnstileRetry", .serialized)
struct TurnstileRetryTests {
    static let host = "turnstile-retry.example.com"
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

    /// Thread-safe log of every intercepted request (body + headers).
    final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [Data] = []
        private var requests: [URLRequest] = []

        func append(_ request: URLRequest) {
            lock.lock()
            defer { lock.unlock() }
            requests.append(request)
            if let data = bodyData(from: request) {
                bodies.append(data)
            }
        }

        var allBodies: [Data] {
            lock.lock()
            defer { lock.unlock() }
            return bodies
        }

        var allRequests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return requests
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

    static func turnstileRejection() throws -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: URL(string: "https://\(host)/api/v1/feedback")!,
            statusCode: 403,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json", "X-Request-Id": "req-ts-1"]
        )!
        return (response, try encodeJSON(["error": "Human verification (Turnstile) is required"]))
    }

    static func uploadSessionJSON() throws -> Data {
        try encodeJSON([
            "session": [
                "sessionId": "sess-1",
                "sessionToken": "stok-abc",
                "expiresAt": NSNull(),
                "maxFileSizeBytes": NSNull(),
                "maxFiles": NSNull()
            ],
            "files": [[
                "clientFileId": "file-1",
                "uploadId": "upl-1",
                "uploadUrl": "https://\(host)/api/v1/uploads/upl-1",
                "maxSizeBytes": NSNull()
            ]]
        ])
    }

    // MARK: Single retry with a fresh token (issue requirement 3)

    @Test func gatedSubmissionRetriesOnceWithFreshTokenAndSucceeds() async throws {
        let provider = TokenProvider(["stale-token-0001", "fresh-token-0002"])
        let log = RequestLog()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            log.append(request)
            if log.allBodies.count == 1 {
                return try Self.turnstileRejection()
            }
            return (makeHTTPResponse(status: 200), try encodeJSON(feedbackReceipt))
        }

        let client = makeClient(turnstileTokenProvider: { await provider.next() })
        let result = try await client.submit(
            FeedbackDraft(title: "Title", description: "Description", platform: .ios)
        )

        #expect(result.submissionId == "s-1")
        #expect(log.allBodies.count == 2)
        #expect(provider.callCount == 2)

        let first = try #require(parseJSONDict(log.allBodies[0]))
        let second = try #require(parseJSONDict(log.allBodies[1]))
        #expect(first["turnstileToken"] as? String == "stale-token-0001")
        #expect(second["turnstileToken"] as? String == "fresh-token-0002")

        // Each attempt carries its own correlation id.
        let firstID = log.allRequests[0].value(forHTTPHeaderField: "X-Request-Id")
        let secondID = log.allRequests[1].value(forHTTPHeaderField: "X-Request-Id")
        #expect(firstID != nil && secondID != nil && firstID != secondID)
    }

    @Test func gatedFeatureRequestRetrySendsFreshTokenAndSucceeds() async throws {
        let provider = TokenProvider(["stale-token-0001", "fresh-token-0002"])
        let log = RequestLog()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            log.append(request)
            if log.allBodies.count == 1 {
                return try Self.turnstileRejection()
            }
            return (makeHTTPResponse(status: 201), try encodeJSON(featureRequestReceipt))
        }

        let client = makeClient(turnstileTokenProvider: { await provider.next() })
        let result = try await client.submitFeatureRequest(
            FeatureRequestDraft(title: "Title", description: "Description"),
            userToken: "user-1"
        )

        #expect(result.featureRequestId == "fr-1")
        let second = try #require(parseJSONDict(log.allBodies[1]))
        #expect(second["turnstileToken"] as? String == "fresh-token-0002")
    }

    @Test func rejectionWithoutProviderThrowsAfterSingleAttempt() async throws {
        let log = RequestLog()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            log.append(request)
            return try Self.turnstileRejection()
        }

        let client = makeClient()
        do {
            _ = try await client.submit(
                FeedbackDraft(title: "Title", description: "Description", platform: .ios)
            )
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            guard case .turnstileRequired = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
            #expect(log.allBodies.count == 1)
        }
    }

    @Test func rejectionWithExhaustedProviderThrowsOriginalErrorWithoutRetry() async throws {
        // The provider yields nothing on either consultation: the first
        // attempt goes out without a token and no retry is attempted.
        let provider = TokenProvider([nil, nil])
        let log = RequestLog()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            log.append(request)
            return try Self.turnstileRejection()
        }

        let client = makeClient(turnstileTokenProvider: { await provider.next() })
        do {
            _ = try await client.submit(
                FeedbackDraft(title: "Title", description: "Description", platform: .ios)
            )
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            guard case .turnstileRequired = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
            #expect(log.allBodies.count == 1)
            #expect(provider.callCount == 2)
        }
    }

    @Test func retryStillRejectedThrowsTypedErrorAfterExactlyTwoAttempts() async throws {
        let provider = TokenProvider(["tok-1234567890", "tok-9876543210"])
        let log = RequestLog()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            log.append(request)
            return try Self.turnstileRejection()
        }

        let client = makeClient(turnstileTokenProvider: { await provider.next() })
        do {
            _ = try await client.submit(
                FeedbackDraft(title: "Title", description: "Description", platform: .ios)
            )
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            guard case .turnstileRequired = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
            #expect(log.allBodies.count == 2)
            #expect(provider.callCount == 2)
        }
    }

    // MARK: Upload-session provider fallback

    @Test func createUploadSessionFallsBackToProviderToken() async throws {
        let provider = TokenProvider(["tok-1234567890"])
        let log = RequestLog()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            log.append(request)
            return (makeHTTPResponse(status: 201), try Self.uploadSessionJSON())
        }

        let client = makeClient(turnstileTokenProvider: { await provider.next() })
        _ = try await client.createUploadSession(
            files: [FeedbackUploadFileSpec(
                clientFileId: "file-1",
                filename: "f.png",
                contentType: "image/png",
                sizeBytes: 5
            )],
            userToken: "user-1"
        )

        let rawBody = try #require(log.allBodies.first)
        let json = try #require(parseJSONDict(rawBody))
        #expect(json["turnstileToken"] as? String == "tok-1234567890")
    }

    @Test func createUploadSessionExplicitTokenWinsOverProvider() async throws {
        let provider = TokenProvider(["tok-from-provider-123"])
        let log = RequestLog()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            log.append(request)
            return (makeHTTPResponse(status: 201), try Self.uploadSessionJSON())
        }

        let client = makeClient(turnstileTokenProvider: { await provider.next() })
        _ = try await client.createUploadSession(
            files: [FeedbackUploadFileSpec(
                clientFileId: "file-1",
                filename: "f.png",
                contentType: "image/png",
                sizeBytes: 5
            )],
            userToken: "user-1",
            turnstileToken: "tok-explicit-123456"
        )

        let rawBody = try #require(log.allBodies.first)
        let json = try #require(parseJSONDict(rawBody))
        #expect(json["turnstileToken"] as? String == "tok-explicit-123456")
        #expect(provider.callCount == 0)
    }
}
