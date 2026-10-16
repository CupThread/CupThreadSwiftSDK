import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Backend-Delegated Payment-Attribute Signing (issue #405 / SEC-19)

/// The `userAttributesSigner` provider seam: payment-attribute reports are
/// signed wherever the SDK signing secret lives — normally the host's backend
/// — so the secret never ships inside the app binary. The SDK builds the
/// canonical string, the provider HMACs it, and the returned signature and
/// timestamp are sent verbatim.
@Suite("UserAttributesSigningProvider", .serialized)
struct UserAttributesSigningProviderTests {
    static let apiHost = "signing-provider.example.com"
    /// The "server-side" secret — the only place it exists in these tests,
    /// mirroring a backend that holds the real key.
    static let backendSecret = "sec_backend_held_secret_98765"
    static let appKey = "app_signingprovider1"
    static let baseEpoch: Int64 = 1_790_000_030
    /// The device clock in the skew scenarios runs +10 minutes ahead.
    static let deviceSkewSeconds: Int64 = 600

    final class ProviderRecorder: @unchecked Sendable {
        var requests: [UserAttributesSigningRequest] = []
        var callCount = 0
    }

    /// A stub "backend" signer: HMACs the canonical string it receives with
    /// the server-held secret under the canonical string's own timestamp.
    /// An `override` closure replaces the whole response — returning `nil`
    /// makes the provider decline (falling back down the SDK's chain).
    static func backendSigner(
        recording recorder: ProviderRecorder,
        override: (@Sendable (UserAttributesSigningRequest) -> UserAttributesSignature?)? = nil
    ) -> @Sendable (UserAttributesSigningRequest) async throws -> UserAttributesSignature? {
        { request in
            recorder.requests.append(request)
            recorder.callCount += 1
            if let override {
                return override(request)
            }
            return UserAttributesSignature(
                signature: UserAttributesSigner.signature(for: request.canonicalString, secret: backendSecret),
                timestamp: request.arguments.timestamp
            )
        }
    }

    static func makeProviderClient(
        secret: String? = nil,
        serverClock: ServerClock? = nil,
        signer: (@Sendable (UserAttributesSigningRequest) async throws -> UserAttributesSignature?)? = nil
    ) -> FeedbackClient {
        makeClient(
            baseURL: URL(string: "https://\(apiHost)")!,
            appKey: appKey,
            signingSecret: secret,
            serverClock: serverClock,
            userAttributesSigner: signer
        )
    }

    static func successResponse() throws -> (HTTPURLResponse, Data) {
        (
            makeHTTPResponse(),
            try encodeJSON(["ok": true, "updatedAt": "2026-10-16T00:00:00.000Z"])
        )
    }

    static func signatureFailureResponse(status: Int, code: String, requestId: String) throws -> (HTTPURLResponse, Data) {
        (
            makeHTTPResponse(status: status, headers: ["X-Request-Id": requestId]),
            try encodeJSON(["error": code, "code": code])
        )
    }

    private static func makeHTTPDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.string(from: date)
    }

    /// A 401 response whose `Date` header teaches the client the server's
    /// real time (the API-19 offset source).
    static func staleResponse() throws -> (HTTPURLResponse, Data) {
        (
            makeHTTPResponse(
                status: 401,
                headers: [
                    "Date": makeHTTPDateString(Date(timeIntervalSince1970: TimeInterval(baseEpoch))),
                    "X-Request-Id": "req-stale-provider"
                ]
            ),
            try encodeJSON(["error": "stale_signature", "code": "stale_signature"])
        )
    }

    // MARK: - Canonical String Handoff

    @Test func providerReceivesByteIdenticalCanonicalString() async throws {
        let recorder = ProviderRecorder()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in try Self.successResponse() }

        let client = Self.makeProviderClient(signer: Self.backendSigner(recording: recorder))
        _ = try await client.updateUserAttributes(
            isPaying: true,
            plan: "pro",
            mrr: 42.5,
            currency: "USD",
            userToken: "user-provider-canonical"
        )

        let request = try #require(recorder.requests.first)
        let expected = UserAttributesSigner.canonicalString(for: request.arguments)
        #expect(request.canonicalString == expected)
        // The canonical string embeds exactly the eight contract lines, ending
        // with the timestamp the payload carries.
        #expect(request.canonicalString.hasPrefix("cpt-user-attrs-v1\n"))
        #expect(request.canonicalString == request.canonicalString.trimmingCharacters(in: .newlines))
        #expect(request.arguments.appKey == Self.appKey)
        #expect(request.arguments.userToken == "user-provider-canonical")
    }

    // MARK: - Verified Round Trip Without an Embedded Secret

    @Test func backendSignedRoundTripSucceedsWithNoEmbeddedSecret() async throws {
        let requests = CaptureBox<[URLRequest]>()
        requests.value = []
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            requests.value?.append(request)
            return try Self.successResponse()
        }

        let recorder = ProviderRecorder()
        // No `signingSecret` on the configuration and no per-call override:
        // the only signing capability in the process is the stub backend.
        let client = Self.makeProviderClient(signer: Self.backendSigner(recording: recorder))
        let result = try await client.updateUserAttributes(
            isPaying: true,
            plan: "pro",
            mrr: 1200,
            currency: "EUR",
            userToken: "user-provider-verified"
        )

        #expect(result.ok == true)
        let sent = try #require(requests.value)
        #expect(sent.count == 1)
        let rawData = try #require(bodyData(from: sent[0]))
        let json = try #require(parseJSONDict(rawData))
        let timestamp = try #require(json["timestamp"] as? Int64)
        let signature = try #require(json["signature"] as? String)

        // The signature is the backend HMAC of the exact canonical string for
        // the payload the server receives — a verifiable write minted without
        // any client-side secret.
        let expectedCanonical = UserAttributesSigner.canonicalString(
            for: .init(
                appKey: Self.appKey,
                userToken: "user-provider-verified",
                isPaying: .value(true),
                plan: .value("pro"),
                mrr: .value(1200),
                currency: .value("EUR"),
                timestamp: timestamp
            )
        )
        #expect(signature == UserAttributesSigner.signature(for: expectedCanonical, secret: Self.backendSecret))
        let signedRequest = try #require(recorder.requests.first)
        #expect(timestamp == signedRequest.arguments.timestamp)
    }

    @Test func providerTimestampIsSentVerbatim() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return try Self.successResponse()
        }

        let fixedTimestamp: Int64 = 1_773_600_123
        let client = Self.makeProviderClient { _ in
            UserAttributesSignature(signature: String(repeating: "a", count: 64), timestamp: fixedTimestamp)
        }
        _ = try await client.updateUserAttributes(isPaying: true, userToken: "user-provider-verbatim")

        let request = try #require(capture.value)
        let rawData = try #require(bodyData(from: request))
        let json = try #require(parseJSONDict(rawData))
        #expect(json["timestamp"] as? Int64 == fixedTimestamp)
        #expect(json["signature"] as? String == String(repeating: "a", count: 64))
    }

    @Test func providerWinsOverConfiguredSecret() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return try Self.successResponse()
        }

        let providerSignature = String(repeating: "f", count: 64)
        let client = Self.makeProviderClient(
            secret: "sec_embedded_debug_secret",
            signer: { _ in UserAttributesSignature(signature: providerSignature, timestamp: 1_773_600_200) }
        )
        _ = try await client.updateUserAttributes(isPaying: true, userToken: "user-provider-wins")

        let request = try #require(capture.value)
        let rawData = try #require(bodyData(from: request))
        let json = try #require(parseJSONDict(rawData))
        // The provider's signature is on the wire, not the secret-derived one.
        #expect(json["signature"] as? String == providerSignature)
    }

    // MARK: - Fallback Chain

    @Test func decliningProviderFallsBackToConfiguredSecret() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return try Self.successResponse()
        }

        let recorder = ProviderRecorder()
        let secret = "sec_fallback_secret"
        let client = Self.makeProviderClient(
            secret: secret,
            signer: Self.backendSigner(recording: recorder, override: { _ in nil })
        )
        _ = try await client.updateUserAttributes(isPaying: true, userToken: "user-fallback-secret")

        let request = try #require(capture.value)
        let rawData = try #require(bodyData(from: request))
        let json = try #require(parseJSONDict(rawData))
        let timestamp = try #require(json["timestamp"] as? Int64)
        let expectedCanonical = UserAttributesSigner.canonicalString(
            for: .init(appKey: Self.appKey, userToken: "user-fallback-secret", isPaying: .value(true), timestamp: timestamp)
        )
        #expect(json["signature"] as? String == UserAttributesSigner.signature(for: expectedCanonical, secret: secret))
        #expect(recorder.callCount == 1)
    }

    @Test func decliningProviderWithNoSecretSendsUnsigned() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return try Self.successResponse()
        }

        let client = Self.makeProviderClient { _ in nil }
        _ = try await client.updateUserAttributes(isPaying: true, userToken: "user-fallback-unsigned")

        let request = try #require(capture.value)
        let rawData = try #require(bodyData(from: request))
        let json = try #require(parseJSONDict(rawData))
        #expect(json["isPaying"] as? Bool == true)
        #expect(json["signature"] == nil)
        #expect(json["timestamp"] == nil)
    }

    @Test func identityOnlyUpdateDoesNotConsultProvider() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in try Self.successResponse() }

        let recorder = ProviderRecorder()
        let client = Self.makeProviderClient(signer: Self.backendSigner(recording: recorder))
        _ = try await client.updateUserAttributes(userToken: "user-identity-only")

        #expect(recorder.callCount == 0)
    }

    // MARK: - Local Provider-Result Validation

    @Test func malformedProviderSignatureRejectedWithoutNetworkCall() async throws {
        let requests = CaptureBox<[URLRequest]>()
        requests.value = []
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            requests.value?.append(request)
            return try Self.successResponse()
        }

        let client = Self.makeProviderClient { _ in
            UserAttributesSignature(signature: "not-a-signature", timestamp: 1_773_600_300)
        }
        do {
            _ = try await client.updateUserAttributes(isPaying: true, userToken: "user-malformed-sig")
            Issue.record("Expected invalidSignature error")
        } catch let error as FeedbackClientError {
            guard case .invalidSignature(let message, let requestId) = error else {
                Issue.record("Expected .invalidSignature, got \(error)")
                return
            }
            #expect(requestId == nil)
            #expect(message?.contains("malformed signature") == true)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
        // Rejected locally — no request was ever built or sent.
        #expect((requests.value ?? []).isEmpty)
    }

    @Test func providerThrowingPropagatesWithoutNetworkCall() async throws {
        let requests = CaptureBox<[URLRequest]>()
        requests.value = []
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            requests.value?.append(request)
            return try Self.successResponse()
        }

        struct BackendUnreachable: Error {}
        let client = Self.makeProviderClient { _ in throw BackendUnreachable() }
        do {
            _ = try await client.updateUserAttributes(isPaying: true, userToken: "user-provider-throws")
            Issue.record("Expected the provider error to propagate")
        } catch is BackendUnreachable {
            // The host's own backend error surfaces as-is.
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
        #expect((requests.value ?? []).isEmpty)
    }

    // MARK: - Clock-Skew Recovery Through the Provider (API-19)

    @Test func staleSignatureReconsultsProviderWithCorrectedClockAndRetriesOnce() async throws {
        let requests = CaptureBox<[URLRequest]>()
        requests.value = []
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            requests.value?.append(request)
            if requests.value?.count == 1 {
                return try Self.staleResponse()
            }
            return try Self.successResponse()
        }

        // The device clock runs +600 s ahead of the server's `Date` header.
        let recorder = ProviderRecorder()
        let client = Self.makeProviderClient(
            serverClock: ServerClock(now: {
                Date(timeIntervalSince1970: TimeInterval(Self.baseEpoch + Self.deviceSkewSeconds))
            }),
            signer: Self.backendSigner(recording: recorder)
        )
        let result = try await client.updateUserAttributes(isPaying: true, userToken: "user-provider-stale")

        #expect(result.ok == true)
        // Exactly one more provider call and one retried PUT.
        #expect(recorder.callCount == 2)
        let sent = try #require(requests.value)
        #expect(sent.count == 2)

        // First attempt: the skewed device clock.
        #expect(recorder.requests[0].arguments.timestamp == Self.baseEpoch + Self.deviceSkewSeconds)
        // Recovery: the timestamp corrected by the failing response's `Date`
        // header — inside the server's freshness window — and a signature the
        // backend minted over exactly that corrected canonical string.
        let retryTimestamp = recorder.requests[1].arguments.timestamp
        #expect(retryTimestamp == Self.baseEpoch)
        let rawData = try #require(bodyData(from: sent[1]))
        let json = try #require(parseJSONDict(rawData))
        #expect(json["timestamp"] as? Int64 == retryTimestamp)
        let expectedCanonical = UserAttributesSigner.canonicalString(
            for: .init(appKey: Self.appKey, userToken: "user-provider-stale", isPaying: .value(true), timestamp: retryTimestamp)
        )
        #expect(json["signature"] as? String == UserAttributesSigner.signature(for: expectedCanonical, secret: Self.backendSecret))
    }

    @Test func staleSignatureRetriedExactlyOnceThenSurfacesThroughProvider() async throws {
        let requests = CaptureBox<[URLRequest]>()
        requests.value = []
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            requests.value?.append(request)
            return try Self.staleResponse()
        }

        let recorder = ProviderRecorder()
        let client = Self.makeProviderClient(
            serverClock: ServerClock(now: {
                Date(timeIntervalSince1970: TimeInterval(Self.baseEpoch + Self.deviceSkewSeconds))
            }),
            signer: Self.backendSigner(recording: recorder)
        )
        do {
            _ = try await client.updateUserAttributes(isPaying: true, userToken: "user-provider-stale-forever")
            Issue.record("Expected staleSignature error")
        } catch let error as FeedbackClientError {
            guard case .staleSignature = error else {
                Issue.record("Expected .staleSignature, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
        #expect(requests.value?.count == 2)
        #expect(recorder.callCount == 2)
    }

    @Test func invalidSignatureFromServerIsNeverRetriedThroughProvider() async throws {
        let requests = CaptureBox<[URLRequest]>()
        requests.value = []
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            requests.value?.append(request)
            return try Self.signatureFailureResponse(status: 401, code: "invalid_signature", requestId: "req-invalid-provider")
        }

        let recorder = ProviderRecorder()
        let client = Self.makeProviderClient(
            serverClock: ServerClock(now: {
                Date(timeIntervalSince1970: TimeInterval(Self.baseEpoch + Self.deviceSkewSeconds))
            }),
            signer: Self.backendSigner(recording: recorder)
        )
        do {
            _ = try await client.updateUserAttributes(isPaying: true, userToken: "user-provider-invalid")
            Issue.record("Expected invalidSignature error")
        } catch let error as FeedbackClientError {
            guard case .invalidSignature = error else {
                Issue.record("Expected .invalidSignature, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
        // A mismatched backend secret is not a clock problem: one request,
        // one provider call, no retry.
        #expect(requests.value?.count == 1)
        #expect(recorder.callCount == 1)
    }

    // MARK: - Grammar

    @Test func signatureGrammarAcceptsHexAndRejectsEverythingElse() {
        #expect(UserAttributesSignatureGrammar.isValid(String(repeating: "0", count: 64)))
        #expect(UserAttributesSignatureGrammar.isValid(String(repeating: "f", count: 64)))
        #expect(UserAttributesSignatureGrammar.isValid(String(repeating: "A", count: 64)))
        #expect(UserAttributesSignatureGrammar.isValid(String(repeating: "9", count: 63)) == false)
        #expect(UserAttributesSignatureGrammar.isValid(String(repeating: "9", count: 65)) == false)
        #expect(UserAttributesSignatureGrammar.isValid(String(repeating: "g", count: 64)) == false)
        #expect(UserAttributesSignatureGrammar.isValid(String(repeating: " ", count: 64)) == false)
        #expect(UserAttributesSignatureGrammar.isValid("") == false)
    }
}
