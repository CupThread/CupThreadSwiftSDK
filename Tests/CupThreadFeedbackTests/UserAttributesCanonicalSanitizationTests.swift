import Foundation
import Testing
@testable import CupThreadFeedback

/// Pins the canonical-string and wire hardening for `PUT /user` attribute
/// reports (SEC-3): host-supplied strings must not be able to inject lines
/// into the newline-delimited canonical string, and non-finite MRR values
/// must never abort the request inside `JSONEncoder`. The signed canonical
/// string and the transmitted JSON must always describe the same sanitized
/// payload, so a server canonicalizing what it received reconstructs the
/// signature.
@Suite("UserAttributesCanonicalSanitization", .serialized)
struct UserAttributesCanonicalSanitizationTests {
    static let apiHost = "user-attributes-sanitization.example.com"
    static let testSecret = "sec_test_secret_key_12345"
    static let testAppKey = "app_testkey123456"

    static func makeSigningClient(secret: String? = testSecret) -> FeedbackClient {
        makeClient(
            baseURL: URL(string: "https://\(apiHost)")!,
            appKey: testAppKey,
            signingSecret: secret
        )
    }

    // MARK: - Canonical string injection

    @Test func canonicalStringSanitizesNewlinesInStringFields() {
        let canonical = UserAttributesSigner.canonicalString(
            for: .init(
                appKey: "app_demo",
                userToken: "tok_user_123",
                isPaying: true,
                plan: "pro\n1000\nUSD\n1773600000",
                mrr: 1200.0,
                currency: "USD",
                timestamp: 1773600000
            )
        )

        let lines = canonical.components(separatedBy: "\n")
        #expect(lines.count == 8, "Canonical string must contain exactly 8 lines, but had \(lines.count): \(canonical)")
        // The injected record collapses onto the plan's own line — the mrr,
        // currency, and timestamp lines cannot be forged through it.
        #expect(lines[4] == "pro 1000 USD 1773600000")
        #expect(lines[5] == "1200")
        #expect(lines[6] == "USD")
        #expect(lines[7] == "1773600000")
    }

    @Test func canonicalStringSanitizesCarriageReturnsInEveryHostLine() {
        let canonical = UserAttributesSigner.canonicalString(
            for: .init(
                appKey: "app_de\rmo",
                userToken: "tok\r\n_user",
                isPaying: true,
                plan: "pro",
                mrr: 1200.0,
                currency: "US\rD",
                timestamp: 1773600000
            )
        )

        let lines = canonical.components(separatedBy: "\n")
        #expect(lines.count == 8)
        // CRLF collapses to one space, a lone CR to one space.
        #expect(lines[1] == "app_de mo")
        #expect(lines[2] == "tok _user")
        #expect(lines[6] == "US D")
    }

    // MARK: - Non-finite MRR

    @Test func canonicalNumberHandlesNonFiniteDoublesSafely() {
        #expect(UserAttributesSigner.canonicalNumber(Double.nan) == "0")
        #expect(UserAttributesSigner.canonicalNumber(Double.infinity) == "0")
        #expect(UserAttributesSigner.canonicalNumber(-Double.infinity) == "0")
    }

    // MARK: - Wire consistency

    @Test func updateUserAttributesSanitizesHostileInputOnTheSignedWire() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["ok": true, "updatedAt": "2026-09-16T00:00:00.000Z"]))
        }

        let token = "user-uuid-hostile-input"
        let client = Self.makeSigningClient()
        let fixedTimestamp: Int64 = 1773600300

        // A plan shaped like a smuggled canonical record plus a NaN MRR: the
        // request must still encode, and both the JSON values and the HMAC
        // must describe the sanitized payload (SEC-3).
        _ = try await client.updateUserAttributes(
            isPaying: true,
            plan: "pro\n1000\nUSD\n\(fixedTimestamp)",
            mrr: Double.nan,
            currency: "EUR",
            userToken: token,
            timestamp: fixedTimestamp
        )

        let request = try #require(capture.value)
        let rawData = try #require(bodyData(from: request))
        let json = try #require(parseJSONDict(rawData))

        let sanitizedPlan = "pro 1000 USD \(fixedTimestamp)"
        #expect(json["plan"] as? String == sanitizedPlan)
        #expect(json["mrr"] as? Double == 0)
        #expect(json["currency"] as? String == "EUR")

        // A server canonicalizing exactly what it received must reconstruct
        // the same signature: every line the client signed is a line the
        // server sees.
        let signature = try #require(json["signature"] as? String)
        let serverSideCanonical = [
            "cpt-user-attrs-v1",
            Self.testAppKey,
            token,
            "true",
            sanitizedPlan,
            "0",
            "EUR",
            "\(fixedTimestamp)"
        ].joined(separator: "\n")
        #expect(signature == UserAttributesSigner.signature(for: serverSideCanonical, secret: Self.testSecret))
    }

    @Test func updateUserAttributesSanitizesWireValuesWithoutSignature() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["ok": true, "updatedAt": "2026-09-16T00:00:00.000Z"]))
        }

        // The identity path has no signature to desynchronize, but the stored
        // values must still be the sanitized lines, and a NaN MRR must not
        // turn into a local encoding failure.
        let client = Self.makeSigningClient(secret: nil)
        _ = try await client.updateUserAttributes(
            plan: "pro\r\ninject",
            mrr: Double.infinity,
            userToken: "user-uuid-unsigned-hostile"
        )

        let request = try #require(capture.value)
        let rawData = try #require(bodyData(from: request))
        let json = try #require(parseJSONDict(rawData))

        #expect(json["plan"] as? String == "pro inject")
        #expect(json["mrr"] as? Double == 0)
        #expect(json["signature"] == nil)
    }
}
