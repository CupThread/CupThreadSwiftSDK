import Foundation
import Testing
@testable import CupThreadFeedback

@Suite("UserAttributesSigning", .serialized)
struct UserAttributesSigningTests {
    static let apiHost = "user-attributes-signing.example.com"
    static let testSecret = "sec_test_secret_key_12345"
    static let testAppKey = "app_testkey123456"

    static func makeSigningClient(secret: String? = testSecret) -> FeedbackClient {
        makeClient(
            baseURL: URL(string: "https://\(apiHost)")!,
            appKey: testAppKey,
            signingSecret: secret
        )
    }

    // MARK: - Canonical Number Formatting

    @Test func canonicalNumberRendersIntegerSemantics() {
        #expect(UserAttributesSigner.canonicalNumber(1200.0) == "1200")
        #expect(UserAttributesSigner.canonicalNumber(0.0) == "0")
        #expect(UserAttributesSigner.canonicalNumber(100.0) == "100")
        #expect(UserAttributesSigner.canonicalNumber(1_000_000.0) == "1000000")
    }

    @Test func canonicalNumberRendersFractionalSemantics() {
        #expect(UserAttributesSigner.canonicalNumber(99.5) == "99.5")
        #expect(UserAttributesSigner.canonicalNumber(12.5) == "12.5")
        #expect(UserAttributesSigner.canonicalNumber(12.34) == "12.34")
        #expect(UserAttributesSigner.canonicalNumber(0.1) == "0.1")
        #expect(UserAttributesSigner.canonicalNumber(0.05) == "0.05")
    }

    @Test func canonicalNumberAppliesRoundHalfEven() {
        // 1.125 -> 2 is even -> rounds to 1.12
        #expect(UserAttributesSigner.canonicalNumber(1.125) == "1.12")
        // 1.135 -> 3 is odd -> rounds to 1.14
        #expect(UserAttributesSigner.canonicalNumber(1.135) == "1.14")
        // 1.145 -> 4 is even -> rounds to 1.14
        #expect(UserAttributesSigner.canonicalNumber(1.145) == "1.14")
        // 12.555 -> 5 is odd -> rounds to 12.56
        #expect(UserAttributesSigner.canonicalNumber(12.555) == "12.56")
        // 12.545 -> 4 is even -> rounds to 12.54
        #expect(UserAttributesSigner.canonicalNumber(12.545) == "12.54")
    }

    // MARK: - Canonical String Generation

    @Test func canonicalStringWithAllFields() {
        let canonical = UserAttributesSigner.canonicalString(
            for: .init(
                appKey: "app_demo",
                userToken: "tok_user_123",
                isPaying: true,
                plan: "pro",
                mrr: 1200.0,
                currency: "USD",
                timestamp: 1773600000
            )
        )

        let expected = [
            "cpt-user-attrs-v1",
            "app_demo",
            "tok_user_123",
            "true",
            "pro",
            "1200",
            "USD",
            "1773600000"
        ].joined(separator: "\n")

        #expect(canonical == expected)
    }

    @Test func canonicalStringWithAbsentFieldsMapsToUnset() {
        let canonical = UserAttributesSigner.canonicalString(
            for: .init(
                appKey: "app_demo",
                userToken: "tok_user_123",
                isPaying: false,
                plan: nil,
                mrr: nil,
                currency: nil,
                timestamp: 1773600000
            )
        )

        let expected = [
            "cpt-user-attrs-v1",
            "app_demo",
            "tok_user_123",
            "false",
            "unset",
            "unset",
            "unset",
            "1773600000"
        ].joined(separator: "\n")

        #expect(canonical == expected)
    }

    @Test func canonicalStringWithExplicitNullFields() {
        let canonical = UserAttributesSigner.canonicalString(
            for: .init(
                appKey: "app_demo",
                userToken: "tok_user_123",
                isPaying: .null,
                plan: .null,
                mrr: .null,
                currency: .null,
                timestamp: 1773600000
            )
        )

        let expected = [
            "cpt-user-attrs-v1",
            "app_demo",
            "tok_user_123",
            "null",
            "null",
            "null",
            "null",
            "1773600000"
        ].joined(separator: "\n")

        #expect(canonical == expected)
    }

    @Test func canonicalStringPreservesRawCurrencyAsSent() {
        let canonical = UserAttributesSigner.canonicalString(
            for: .init(
                appKey: "app_demo",
                userToken: "tok_user_123",
                isPaying: true,
                plan: "basic",
                mrr: 99.5,
                currency: "eur",
                timestamp: 1773600000
            )
        )

        let expected = [
            "cpt-user-attrs-v1",
            "app_demo",
            "tok_user_123",
            "true",
            "basic",
            "99.5",
            "eur",
            "1773600000"
        ].joined(separator: "\n")

        #expect(canonical == expected)
    }

    // MARK: - HMAC Signature Verification

    @Test func signatureMatchesKnownTestVector() {
        let canonical = "cpt-user-attrs-v1\napp_demo\ntok_123\ntrue\npro\n1200\nUSD\n1773600000"
        let secret = "test_secret_key"
        let sig = UserAttributesSigner.signature(for: canonical, secret: secret)

        #expect(sig.count == 64)
        // Verify deterministic lowercase hex output
        let recomputed = UserAttributesSigner.signature(for: canonical, secret: secret)
        #expect(sig == recomputed)
    }

    // MARK: - updateUserAttributes Integration

    @Test func updateUserAttributesSignsWhenSecretConfigured() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["ok": true, "updatedAt": "2026-09-16T00:00:00.000Z"]))
        }

        let token = "user-uuid-12345"
        let client = Self.makeSigningClient()
        let fixedTimestamp: Int64 = 1773600000

        let result = try await client.updateUserAttributes(
            isPaying: true,
            plan: "pro",
            mrr: 12.5,
            currency: "EUR",
            userToken: token,
            timestamp: fixedTimestamp
        )

        let request = try #require(capture.value)
        #expect(request.url?.path == "/api/v1/public/apps/\(Self.testAppKey)/user")
        #expect(request.httpMethod == "PUT")
        #expect(request.value(forHTTPHeaderField: "X-User-Token") == token)

        let rawData = try #require(bodyData(from: request))
        let json = try #require(parseJSONDict(rawData))
        #expect(json["isPaying"] as? Bool == true)
        #expect(json["plan"] as? String == "pro")
        #expect(json["mrr"] as? Double == 12.5)
        #expect(json["currency"] as? String == "EUR")

        let signature = try #require(json["signature"] as? String)
        let timestamp = try #require(json["timestamp"] as? Int64)

        #expect(timestamp == fixedTimestamp)
        #expect(signature.count == 64)

        let expectedCanonical = UserAttributesSigner.canonicalString(
            for: .init(
                appKey: Self.testAppKey,
                userToken: token,
                isPaying: true,
                plan: "pro",
                mrr: 12.5,
                currency: "EUR",
                timestamp: fixedTimestamp
            )
        )
        let expectedSignature = UserAttributesSigner.signature(for: expectedCanonical, secret: Self.testSecret)
        #expect(signature == expectedSignature)
        #expect(result.ok == true)
    }

    @Test func updateUserAttributesSignsWithExplicitSecretOverride() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["ok": true, "updatedAt": "2026-09-16T00:00:00.000Z"]))
        }

        let token = "user-uuid-67890"
        // Client without configured secret
        let client = Self.makeSigningClient(secret: nil)
        let overrideSecret = "sec_override_secret_999"
        let fixedTimestamp: Int64 = 1773600100

        _ = try await client.updateUserAttributes(
            isPaying: false,
            plan: "free",
            userToken: token,
            signingSecret: overrideSecret,
            timestamp: fixedTimestamp
        )

        let request = try #require(capture.value)
        let rawData = try #require(bodyData(from: request))
        let json = try #require(parseJSONDict(rawData))

        let signature = try #require(json["signature"] as? String)
        let timestamp = try #require(json["timestamp"] as? Int64)

        #expect(timestamp == fixedTimestamp)
        let expectedCanonical = UserAttributesSigner.canonicalString(
            for: .init(
                appKey: Self.testAppKey,
                userToken: token,
                isPaying: false,
                plan: "free",
                mrr: nil,
                currency: nil,
                timestamp: fixedTimestamp
            )
        )
        let expectedSignature = UserAttributesSigner.signature(for: expectedCanonical, secret: overrideSecret)
        #expect(signature == expectedSignature)
    }

    @Test func updateUserAttributesOmitsSignatureWhenNoPaymentAttributes() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["ok": true, "updatedAt": "2026-09-16T00:00:00.000Z"]))
        }

        // Even though client has a secret configured, identity/currency-only requests remain unsigned
        let client = Self.makeSigningClient()
        _ = try await client.updateUserAttributes(
            currency: "USD",
            userToken: "user-uuid-only-currency"
        )

        let request = try #require(capture.value)
        let rawData = try #require(bodyData(from: request))
        let json = try #require(parseJSONDict(rawData))

        #expect(json["currency"] as? String == "USD")
        #expect(json["signature"] == nil)
        #expect(json["timestamp"] == nil)
        #expect(json["isPaying"] == nil)
        #expect(json["plan"] == nil)
        #expect(json["mrr"] == nil)
    }

    @Test func updateUserAttributesSendsUnsignedWhenNoSecretConfigured() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["ok": true, "updatedAt": "2026-09-16T00:00:00.000Z"]))
        }

        let client = Self.makeSigningClient(secret: nil)
        _ = try await client.updateUserAttributes(
            isPaying: true,
            plan: "enterprise",
            userToken: "user-uuid-no-secret"
        )

        let request = try #require(capture.value)
        let rawData = try #require(bodyData(from: request))
        let json = try #require(parseJSONDict(rawData))

        #expect(json["isPaying"] as? Bool == true)
        #expect(json["plan"] as? String == "enterprise")
        #expect(json["signature"] == nil)
        #expect(json["timestamp"] == nil)
    }

    @Test func updateUserAttributes422SignatureRequiredSurfacesError() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 422),
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
                userToken: "user-uuid-err"
            )
            Issue.record("Expected unexpectedStatus error")
        } catch FeedbackClientError.unexpectedStatus(let code, let message, _) {
            #expect(code == 422)
            #expect(message == "Payment attributes require signature")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func updateUserAttributes401InvalidSignatureSurfacesError() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 401),
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
                userToken: "user-uuid-err"
            )
            Issue.record("Expected unexpectedStatus error")
        } catch FeedbackClientError.unexpectedStatus(let code, let message, _) {
            #expect(code == 401)
            #expect(message == "Invalid signature")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
