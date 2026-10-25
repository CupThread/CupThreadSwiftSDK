import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Local Provider-Result Validation (issue #405 / SEC-19, issue #579)

/// The provider result's local gate: a well-behaved signer's values reach the
/// wire verbatim, while a malformed signature (#405) or a timestamp that does
/// not match the canonical string it was asked to sign (#579) fails fast
/// locally — before any request is built or sent — because the server can
/// only answer those with an unretryable `invalid_signature`.
@Suite("SigningProviderResultValidation", .serialized)
struct SigningProviderResultValidationTests {
    /// A dedicated mock host: `MockURLProtocol` handlers are registered per
    /// host process-wide, and these tests run concurrently with the main
    /// `UserAttributesSigningProvider` suite.
    static let apiHost = "signing-provider-validation.example.com"

    /// A well-behaved provider echoes the timestamp embedded in the
    /// canonical string it was asked to sign; that value reaches the wire
    /// verbatim (#579).
    @Test func wellBehavedProviderTimestampIsSentVerbatim() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return try UserAttributesSigningProviderTests.successResponse()
        }

        let recorder = UserAttributesSigningProviderTests.ProviderRecorder()
        let client = UserAttributesSigningProviderTests.makeProviderClient(
            host: Self.apiHost,
            signer: UserAttributesSigningProviderTests.backendSigner(recording: recorder, override: { request in
                UserAttributesSignature(
                    signature: String(repeating: "a", count: 64),
                    timestamp: request.arguments.timestamp
                )
            })
        )
        _ = try await client.updateUserAttributes(isPaying: true, userToken: "user-provider-verbatim")

        let request = try #require(capture.value)
        let rawData = try #require(bodyData(from: request))
        let json = try #require(parseJSONDict(rawData))
        let signedRequest = try #require(recorder.requests.first)
        #expect(json["timestamp"] as? Int64 == signedRequest.arguments.timestamp)
        #expect(json["signature"] as? String == String(repeating: "a", count: 64))
    }

    /// A natural provider misreading — the backend signs the canonical
    /// string but stamps its own signing time — can only verify as
    /// `invalid_signature` server-side (the server rebuilds the canonical
    /// string from the payload's timestamp), and `.invalidSignature` is
    /// never retried, so the SDK fails fast locally without spending the
    /// request (#579).
    @Test func providerTimestampMismatchFailsFastWithoutNetworkCall() async throws {
        let requests = CaptureBox<[URLRequest]>()
        requests.value = []
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            requests.value?.append(request)
            return try UserAttributesSigningProviderTests.successResponse()
        }

        let client = UserAttributesSigningProviderTests.makeProviderClient(host: Self.apiHost) { request in
            UserAttributesSignature(
                signature: String(repeating: "a", count: 64),
                timestamp: request.arguments.timestamp + 60
            )
        }
        do {
            _ = try await client.updateUserAttributes(isPaying: true, userToken: "user-provider-timestamp-mismatch")
            Issue.record("Expected invalidSignature error")
        } catch let error as FeedbackClientError {
            guard case .invalidSignature(let message, let requestId) = error else {
                Issue.record("Expected .invalidSignature, got \(error)")
                return
            }
            #expect(requestId == nil)
            #expect(message?.contains("timestamp") == true)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
        // Rejected locally — no request was ever built or sent.
        #expect((requests.value ?? []).isEmpty)
    }

    @Test func malformedProviderSignatureRejectedWithoutNetworkCall() async throws {
        let requests = CaptureBox<[URLRequest]>()
        requests.value = []
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            requests.value?.append(request)
            return try UserAttributesSigningProviderTests.successResponse()
        }

        let client = UserAttributesSigningProviderTests.makeProviderClient(host: Self.apiHost) { _ in
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
            return try UserAttributesSigningProviderTests.successResponse()
        }

        struct BackendUnreachable: Error {}
        let client = UserAttributesSigningProviderTests.makeProviderClient(host: Self.apiHost) { _ in throw BackendUnreachable() }
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
}
