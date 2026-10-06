import Foundation
import Testing
@testable import CupThreadFeedback

/// Typed mapping of the payment-attribute signature failure envelopes on
/// `PUT /api/v1/public/apps/{appKey}/user` (issue #238): the 422/401
/// signature codes surface dedicated `FeedbackClientError` cases — never
/// `.unexpectedStatus` with the signed-in 401 copy — with the response's
/// `X-Request-Id` preserved.
@Suite("UserAttributesSignatureErrors", .serialized)
struct UserAttributesSignatureErrorTests {
    static let apiHost = "user-attributes-signature-errors.example.com"
    static let testAppKey = "app_testkey123456"

    static func makeSigningClient(secret: String? = UserAttributesSigningTests.testSecret) -> FeedbackClient {
        makeClient(
            baseURL: URL(string: "https://\(apiHost)")!,
            appKey: testAppKey,
            signingSecret: secret
        )
    }

    @Test func signatureRequiredEnvelopeSurfacesTypedError() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 422, headers: ["X-Request-Id": "req-422-sign-req"]),
                try encodeJSON([
                    "error": "Payment attributes require signature",
                    "code": "payment_attributes_require_signature"
                ])
            )
        }

        let client = Self.makeSigningClient(secret: nil)
        do {
            _ = try await client.updateUserAttributes(
                isPaying: true,
                userToken: "user-uuid-sig-err"
            )
            Issue.record("Expected paymentAttributesRequireSignature error")
        } catch let error as FeedbackClientError {
            guard case .paymentAttributesRequireSignature(let message, let requestId) = error else {
                Issue.record("Expected .paymentAttributesRequireSignature, got \(error)")
                return
            }
            #expect(message == "Payment attributes require signature")
            #expect(requestId == "req-422-sign-req")
            #expect(error.errorDescription?.contains("req-422-sign-req") == true)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func signingSecretNotConfiguredEnvelopeSurfacesTypedError() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 422, headers: ["X-Request-Id": "req-422-no-secret"]),
                try encodeJSON([
                    "error": "SDK signing secret not configured",
                    "code": "sdk_signing_secret_not_configured"
                ])
            )
        }

        let client = Self.makeSigningClient()
        do {
            _ = try await client.updateUserAttributes(
                isPaying: true,
                plan: "pro",
                userToken: "user-uuid-sig-err"
            )
            Issue.record("Expected sdkSigningSecretNotConfigured error")
        } catch let error as FeedbackClientError {
            guard case .sdkSigningSecretNotConfigured(let message, let requestId) = error else {
                Issue.record("Expected .sdkSigningSecretNotConfigured, got \(error)")
                return
            }
            #expect(message == "SDK signing secret not configured")
            #expect(requestId == "req-422-no-secret")
            #expect(error.errorDescription?.contains("req-422-no-secret") == true)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func invalidSignatureEnvelopeSurfacesTypedError() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 401, headers: ["X-Request-Id": "req-401-invalid"]),
                try encodeJSON([
                    "error": "Invalid signature",
                    "code": "invalid_signature"
                ])
            )
        }

        let client = Self.makeSigningClient()
        do {
            _ = try await client.updateUserAttributes(
                isPaying: true,
                userToken: "user-uuid-sig-err"
            )
            Issue.record("Expected invalidSignature error")
        } catch let error as FeedbackClientError {
            guard case .invalidSignature(let message, let requestId) = error else {
                Issue.record("Expected .invalidSignature, got \(error)")
                return
            }
            #expect(message == "Invalid signature")
            #expect(requestId == "req-401-invalid")

            // A signing failure must never render as the signed-in 401 copy (#238).
            let description = try #require(error.errorDescription)
            let unauthorized = CupThreadStrings.tr("cupthread.error.http_unauthorized")
            #expect(description != unauthorized)
            #expect(!description.hasPrefix(unauthorized))
            #expect(description.contains("req-401-invalid"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func staleSignatureEnvelopeSurfacesTypedError() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 401, headers: ["X-Request-Id": "req-401-stale"]),
                try encodeJSON([
                    "error": "Stale signature",
                    "code": "stale_signature"
                ])
            )
        }

        let client = Self.makeSigningClient()
        do {
            _ = try await client.updateUserAttributes(
                isPaying: true,
                userToken: "user-uuid-sig-err"
            )
            Issue.record("Expected staleSignature error")
        } catch let error as FeedbackClientError {
            guard case .staleSignature(_, let requestId) = error else {
                Issue.record("Expected .staleSignature, got \(error)")
                return
            }
            #expect(requestId == "req-401-stale")

            // Freshness/clock-skew copy, not the signed-in unauthorized copy (#238).
            let description = try #require(error.errorDescription)
            #expect(
                description == CupThreadStrings.tr("cupthread.error.stale_signature")
                    + " (request id: req-401-stale)"
            )
            #expect(
                description != CupThreadStrings.tr("cupthread.error.http_unauthorized")
                    + " (request id: req-401-stale)"
            )
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func authenticationRequiredEnvelopeStillMapsToAuthenticationRequired() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 401),
                try encodeJSON([
                    "error": "Authentication required",
                    "code": "authentication_required"
                ])
            )
        }

        let client = Self.makeSigningClient()
        do {
            _ = try await client.updateUserAttributes(
                isPaying: true,
                userToken: "user-uuid-sig-err"
            )
            Issue.record("Expected authenticationRequired error")
        } catch FeedbackClientError.authenticationRequired {
            // Unchanged: the signed-in envelope keeps its dedicated case.
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func unknown401CodeStillFallsBackToUnexpectedStatus() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 401),
                try encodeJSON([
                    "error": "Something else went wrong",
                    "code": "totally_unknown_401_code"
                ])
            )
        }

        let client = Self.makeSigningClient()
        do {
            _ = try await client.updateUserAttributes(
                isPaying: true,
                userToken: "user-uuid-sig-err"
            )
            Issue.record("Expected unexpectedStatus error")
        } catch FeedbackClientError.unexpectedStatus(let code, let message, _) {
            #expect(code == 401)
            #expect(message == "Something else went wrong")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
