import Foundation
import Testing
@testable import CupThreadFeedback

@Suite("UserAttributes", .serialized)
struct UserAttributesTests {
    static let apiHost = "user-attributes.example.com"
    static let testSecret = "sec_test_secret_key_12345"
    static let testAppKey = "app_testkey123456"

    static func makeSigningClient(secret: String? = testSecret) -> FeedbackClient {
        makeClient(
            baseURL: URL(string: "https://\(apiHost)")!,
            appKey: testAppKey,
            signingSecret: secret
        )
    }

    // MARK: - Payload Serialization

    @Test func payloadEncodesExplicitNullForClearedPlanAndMRR() throws {
        let payload = UserAttributesWirePayload(
            isPaying: .value(false),
            plan: .null,
            mrr: .null,
            currency: .unset,
            signature: "sig123",
            timestamp: 1700000000
        )
        let data = try JSONEncoder().encode(payload)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["isPaying"] as? Bool == false)
        #expect(json["plan"] is NSNull)
        #expect(json["mrr"] is NSNull)
        #expect(json["currency"] == nil)
        #expect(json["signature"] as? String == "sig123")
        #expect(json["timestamp"] as? Int64 == 1700000000)
    }

    @Test func payloadOmitsUnsetFields() throws {
        let payload = UserAttributesWirePayload(
            isPaying: .unset,
            plan: .unset,
            mrr: .unset,
            currency: .unset,
            signature: nil,
            timestamp: nil
        )
        let data = try JSONEncoder().encode(payload)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["isPaying"] == nil)
        #expect(json["plan"] == nil)
        #expect(json["mrr"] == nil)
        #expect(json["currency"] == nil)
        #expect(json["signature"] == nil)
        #expect(json["timestamp"] == nil)
    }

    @Test func payloadEncodesExplicitNullForIsPayingAndCurrency() throws {
        let payload = UserAttributesWirePayload(
            isPaying: .null,
            plan: .unset,
            mrr: .unset,
            currency: .null,
            signature: nil,
            timestamp: nil
        )
        let data = try JSONEncoder().encode(payload)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["isPaying"] is NSNull)
        #expect(json["plan"] == nil)
        #expect(json["mrr"] == nil)
        #expect(json["currency"] is NSNull)
    }

    @Test func payloadEncodesExplicitValues() throws {
        let payload = UserAttributesWirePayload(
            isPaying: .value(true),
            plan: .value("enterprise"),
            mrr: .value(299.99),
            currency: .value("USD"),
            signature: "sig_val",
            timestamp: 1773600000
        )
        let data = try JSONEncoder().encode(payload)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["isPaying"] as? Bool == true)
        #expect(json["plan"] as? String == "enterprise")
        #expect(json["mrr"] as? Double == 299.99)
        #expect(json["currency"] as? String == "USD")
        #expect(json["signature"] as? String == "sig_val")
        #expect(json["timestamp"] as? Int64 == 1773600000)
    }

    // MARK: - Integration with FeedbackClient.updateUserAttributes

    @Test func updateUserAttributesWithExplicitNullSignsAndSendsWireNulls() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["ok": true, "updatedAt": "2026-09-26T00:00:00.000Z"]))
        }

        let token = "user-uuid-churned-123"
        let client = Self.makeSigningClient()
        let fixedTimestamp: Int64 = 1773600000

        let result = try await client.updateUserAttributes(
            isPaying: .value(false),
            plan: .null,
            mrr: .null,
            currency: .unset,
            userToken: token,
            timestamp: fixedTimestamp
        )

        let request = try #require(capture.value)
        #expect(request.url?.path == "/api/v1/public/apps/\(Self.testAppKey)/user")
        #expect(request.httpMethod == "PUT")
        #expect(request.value(forHTTPHeaderField: "X-User-Token") == token)

        let rawData = try #require(bodyData(from: request))
        let json = try #require(parseJSONDict(rawData))

        #expect(json["isPaying"] as? Bool == false)
        #expect(json["plan"] is NSNull)
        #expect(json["mrr"] is NSNull)
        #expect(json["currency"] == nil)

        let signature = try #require(json["signature"] as? String)
        let timestamp = try #require(json["timestamp"] as? Int64)
        #expect(timestamp == fixedTimestamp)

        let expectedCanonical = UserAttributesSigner.canonicalString(
            for: .init(
                appKey: Self.testAppKey,
                userToken: token,
                isPaying: .value(false),
                plan: .null,
                mrr: .null,
                currency: .unset,
                timestamp: fixedTimestamp
            )
        )
        let expectedSignature = UserAttributesSigner.signature(for: expectedCanonical, secret: Self.testSecret)
        #expect(signature == expectedSignature)
        #expect(result.ok == true)
    }

    @Test func updateUserAttributesWithFieldValuesSignsProperly() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["ok": true, "updatedAt": "2026-09-26T00:00:00.000Z"]))
        }

        let token = "user-uuid-field-values"
        let client = Self.makeSigningClient()
        let fixedTimestamp: Int64 = 1773600000

        _ = try await client.updateUserAttributes(
            isPaying: .value(true),
            plan: .value("startup"),
            mrr: .value(49.0),
            currency: .value("EUR"),
            userToken: token,
            timestamp: fixedTimestamp
        )

        let request = try #require(capture.value)
        let rawData = try #require(bodyData(from: request))
        let json = try #require(parseJSONDict(rawData))

        #expect(json["isPaying"] as? Bool == true)
        #expect(json["plan"] as? String == "startup")
        #expect(json["mrr"] as? Double == 49.0)
        #expect(json["currency"] as? String == "EUR")

        let signature = try #require(json["signature"] as? String)
        let expectedCanonical = UserAttributesSigner.canonicalString(
            for: .init(
                appKey: Self.testAppKey,
                userToken: token,
                isPaying: .value(true),
                plan: .value("startup"),
                mrr: .value(49.0),
                currency: .value("EUR"),
                timestamp: fixedTimestamp
            )
        )
        let expectedSignature = UserAttributesSigner.signature(for: expectedCanonical, secret: Self.testSecret)
        #expect(signature == expectedSignature)
    }

    @Test func updateUserAttributesWithOnlyUserTokenResolvesWithoutAmbiguity() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["ok": true, "updatedAt": "2026-09-26T00:00:00.000Z"]))
        }

        let token = "user-uuid-token-only"
        let client = Self.makeSigningClient()

        // Calling with userToken only
        _ = try await client.updateUserAttributes(userToken: token)

        let request = try #require(capture.value)
        let rawData = try #require(bodyData(from: request))
        let json = try #require(parseJSONDict(rawData))

        #expect(json["isPaying"] == nil)
        #expect(json["plan"] == nil)
        #expect(json["mrr"] == nil)
        #expect(json["currency"] == nil)
        #expect(json["signature"] == nil)
        #expect(json["timestamp"] == nil)
    }

    @Test func updateUserAttributesClearingPlanWhileSettingMRRToZero() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["ok": true, "updatedAt": "2026-09-26T00:00:00.000Z"]))
        }

        let token = "user-uuid-plan-null-mrr-zero"
        let client = Self.makeSigningClient()
        let fixedTimestamp: Int64 = 1773600000

        _ = try await client.updateUserAttributes(
            plan: .null,
            mrr: .value(0.0),
            userToken: token,
            timestamp: fixedTimestamp
        )

        let request = try #require(capture.value)
        let rawData = try #require(bodyData(from: request))
        let json = try #require(parseJSONDict(rawData))

        #expect(json["isPaying"] == nil)
        #expect(json["plan"] is NSNull)
        #expect(json["mrr"] as? Double == 0.0)
        #expect(json["currency"] == nil)

        let signature = try #require(json["signature"] as? String)
        let expectedCanonical = UserAttributesSigner.canonicalString(
            for: .init(
                appKey: Self.testAppKey,
                userToken: token,
                isPaying: .unset,
                plan: .null,
                mrr: .value(0.0),
                currency: .unset,
                timestamp: fixedTimestamp
            )
        )
        let expectedSignature = UserAttributesSigner.signature(for: expectedCanonical, secret: Self.testSecret)
        #expect(signature == expectedSignature)
    }

    @Test func updateUserAttributesClearingPaymentAttributesWithoutSecretSendsUnsigned() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["ok": true, "updatedAt": "2026-09-26T00:00:00.000Z"]))
        }

        let token = "user-uuid-no-secret-null"
        let client = Self.makeSigningClient(secret: nil)

        _ = try await client.updateUserAttributes(
            plan: .null,
            mrr: .null,
            userToken: token
        )

        let request = try #require(capture.value)
        let rawData = try #require(bodyData(from: request))
        let json = try #require(parseJSONDict(rawData))

        #expect(json["plan"] is NSNull)
        #expect(json["mrr"] is NSNull)
        #expect(json["signature"] == nil)
        #expect(json["timestamp"] == nil)
    }

    @Test func updateUserAttributesClearingOnlyCurrencyDoesNotSign() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["ok": true, "updatedAt": "2026-09-26T00:00:00.000Z"]))
        }

        let token = "user-uuid-currency-null"
        let client = Self.makeSigningClient()

        _ = try await client.updateUserAttributes(
            currency: .null,
            userToken: token
        )

        let request = try #require(capture.value)
        let rawData = try #require(bodyData(from: request))
        let json = try #require(parseJSONDict(rawData))

        #expect(json["isPaying"] == nil)
        #expect(json["plan"] == nil)
        #expect(json["mrr"] == nil)
        #expect(json["currency"] is NSNull)
        #expect(json["signature"] == nil)
        #expect(json["timestamp"] == nil)
    }
}
