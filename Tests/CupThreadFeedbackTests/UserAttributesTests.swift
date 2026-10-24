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

    @Test func payloadEncodingRejectsNullForNonClearableAttributes() throws {
        // The live `EndUserAttributesInput` schema has no null slot for
        // `isPaying` or `currency` (issue #573): the encoder refuses the
        // shape outright so no code path can put it on the wire.
        #expect(throws: FeedbackClientError.attributeNotClearable(attribute: "isPaying")) {
            try JSONEncoder().encode(UserAttributesWirePayload(
                isPaying: .null,
                plan: .unset,
                mrr: .unset,
                currency: .unset
            ))
        }
        #expect(throws: FeedbackClientError.attributeNotClearable(attribute: "currency")) {
            try JSONEncoder().encode(UserAttributesWirePayload(
                isPaying: .unset,
                plan: .unset,
                mrr: .unset,
                currency: .null
            ))
        }
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

    // MARK: - Non-Clearable Attributes Fail Fast (issue #573)

    /// `isPaying` and `currency` carry no null slot in the live
    /// `EndUserAttributesInput` schema: a report clearing them is a
    /// guaranteed HTTP 400 that silently drops every sibling write in the
    /// same PUT. The client rejects them before the canonical string is
    /// built, before any signing material is consulted, and before any
    /// network round trip.
    @Test func updateUserAttributesRejectsNullIsPayingBeforeSigningAndNetwork() async throws {
        let requests = CaptureBox<[URLRequest]>()
        requests.value = []
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            requests.value?.append(request)
            return (makeHTTPResponse(), try encodeJSON(["ok": true, "updatedAt": "2026-09-26T00:00:00.000Z"]))
        }

        let recorder = UserAttributesSigningProviderTests.ProviderRecorder()
        let client = makeClient(
            baseURL: URL(string: "https://\(Self.apiHost)")!,
            appKey: Self.testAppKey,
            signingSecret: Self.testSecret,
            userAttributesSigner: UserAttributesSigningProviderTests.backendSigner(recording: recorder)
        )

        await #expect(throws: FeedbackClientError.attributeNotClearable(attribute: "isPaying")) {
            try await client.updateUserAttributes(
                isPaying: .null,
                plan: .null,
                mrr: .value(0),
                currency: .unset,
                userToken: "user-uuid-ispaying-null",
                signingSecret: Self.testSecret
            )
        }

        // Rejected before any signing material was consumed and before any
        // bytes reached the network — the sibling plan/mrr writes were never
        // silently dropped either.
        #expect((requests.value ?? []).isEmpty)
        #expect(recorder.callCount == 0)
    }

    @Test func updateUserAttributesRejectsNullCurrencyBeforeSigningAndNetwork() async throws {
        let requests = CaptureBox<[URLRequest]>()
        requests.value = []
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            requests.value?.append(request)
            return (makeHTTPResponse(), try encodeJSON(["ok": true, "updatedAt": "2026-09-26T00:00:00.000Z"]))
        }

        let recorder = UserAttributesSigningProviderTests.ProviderRecorder()
        let client = makeClient(
            baseURL: URL(string: "https://\(Self.apiHost)")!,
            appKey: Self.testAppKey,
            signingSecret: Self.testSecret,
            userAttributesSigner: UserAttributesSigningProviderTests.backendSigner(recording: recorder)
        )

        await #expect(throws: FeedbackClientError.attributeNotClearable(attribute: "currency")) {
            try await client.updateUserAttributes(
                currency: .null,
                userToken: "user-uuid-currency-null",
                signingSecret: Self.testSecret
            )
        }

        #expect((requests.value ?? []).isEmpty)
        #expect(recorder.callCount == 0)
    }

    @Test func updateUserAttributesRejectsTheFirstNonClearableNull() async throws {
        let requests = CaptureBox<[URLRequest]>()
        requests.value = []
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            requests.value?.append(request)
            return (makeHTTPResponse(), try encodeJSON(["ok": true, "updatedAt": "2026-09-26T00:00:00.000Z"]))
        }

        let client = Self.makeSigningClient()
        await #expect(throws: FeedbackClientError.attributeNotClearable(attribute: "isPaying")) {
            try await client.updateUserAttributes(
                isPaying: .null,
                currency: .null,
                userToken: "user-uuid-both-null"
            )
        }
        #expect((requests.value ?? []).isEmpty)
    }

    @Test func clearedPlanCanonicalCarriesNullSentinelNonClearableFieldsNeverDo() async throws {
        // The negative canonical guarantee (issue #573): a canonical string
        // built by the client carries the explicit-null sentinel only on the
        // `plan` line — `isPaying` has no null slot in the grammar and
        // `currency: .null` never reaches canonicalization.
        let recorder = UserAttributesSigningProviderTests.ProviderRecorder()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(), try encodeJSON(["ok": true, "updatedAt": "2026-09-26T00:00:00.000Z"]))
        }
        let client = makeClient(
            baseURL: URL(string: "https://\(Self.apiHost)")!,
            appKey: Self.testAppKey,
            userAttributesSigner: UserAttributesSigningProviderTests.backendSigner(recording: recorder)
        )

        _ = try await client.updateUserAttributes(
            isPaying: .value(false),
            plan: .null,
            mrr: .null,
            currency: .unset,
            userToken: "user-uuid-canonical-null"
        )

        let canonical = try #require(recorder.requests.first?.canonicalString)
        let lines = canonical.components(separatedBy: "\n")
        #expect(lines.count == 8)
        #expect(lines[3] == "false", "isPaying line must be a concrete value or the absent sentinel, never 'null'")
        #expect(lines[4] == "null", "plan is nullable server-side and keeps its explicit-null sentinel")
        #expect(lines[6] == "unset", "currency line must be a value or the absent sentinel, never 'null'")

        // Direct canonical construction mirrors the grammar: `.null` for the
        // non-nullable boolean renders as the absent sentinel, so the
        // isPaying line can structurally never read `null`.
        let directCanonical = UserAttributesSigner.canonicalString(
            for: .init(
                appKey: Self.testAppKey,
                userToken: "user-uuid-canonical-null",
                isPaying: .null,
                plan: .unset,
                mrr: .unset,
                currency: .unset,
                timestamp: 1_773_600_000
            )
        )
        #expect(directCanonical.components(separatedBy: "\n")[3] == "unset")
    }
}
