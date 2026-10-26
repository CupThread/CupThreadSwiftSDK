import Foundation
import Testing
@testable import CupThreadFeedback

/// Value-bounds preflight for `PUT /api/v1/public/apps/{appKey}/user`
/// (issue #607): a `plan`, `mrr`, or `currency` the live
/// `EndUserAttributesInput` schema can only reject is refused locally —
/// before the backend-delegated signer provider is consulted (a network
/// round trip for most SEC-19 hosts), before the embedded secret HMACs,
/// and before any bytes reach the network. The whole report is validated
/// as one object server-side, so dispatching a doomed report would also
/// silently drop every sibling write in the same PUT — the failure mode
/// #573 fixed for `.null`, reached here through ordinary values.
@Suite("UserAttributeValueBounds", .serialized)
struct UserAttributeValueBoundsTests {
    static let apiHost = "attribute-bounds.example.com"
    static let testSecret = "sec_bounds_secret_key_12345"
    static let testAppKey = "app_testkey123456"

    /// A client with **both** signing materials installed: the preflight
    /// under test must throw before either is consulted.
    static func makeFullySignedClient() -> (FeedbackClient, UserAttributesSigningProviderTests.ProviderRecorder) {
        let recorder = UserAttributesSigningProviderTests.ProviderRecorder()
        let client = makeClient(
            baseURL: URL(string: "https://\(apiHost)")!,
            appKey: testAppKey,
            signingSecret: testSecret,
            userAttributesSigner: UserAttributesSigningProviderTests.backendSigner(recording: recorder)
        )
        return (client, recorder)
    }

    static func recordRequests() -> CaptureBox<[URLRequest]> {
        let requests = CaptureBox<[URLRequest]>()
        requests.value = []
        MockURLProtocol.setHandler(forHost: apiHost) { request in
            requests.value?.append(request)
            return (makeHTTPResponse(), try encodeJSON(["ok": true, "updatedAt": "2026-10-26T00:00:00.000Z"]))
        }
        return requests
    }

    /// Shared rejection assertion: typed error, zero signer calls, zero
    /// requests — the report never left the process.
    private func assertRejectedBeforeSigning(
        recording requests: CaptureBox<[URLRequest]>,
        recorder: UserAttributesSigningProviderTests.ProviderRecorder,
        attribute: String,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ attempt: () async throws -> Void
    ) async {
        do {
            try await attempt()
            Issue.record("Expected .invalidAttributeValue for \(attribute)", sourceLocation: sourceLocation)
        } catch let error as FeedbackClientError {
            guard case .invalidAttributeValue(let rejected, _, let requestId) = error else {
                Issue.record("Expected .invalidAttributeValue, got \(error)", sourceLocation: sourceLocation)
                return
            }
            #expect(rejected == attribute, "wrong attribute named: \(rejected)", sourceLocation: sourceLocation)
            #expect(requestId == nil, "a local rejection carries no request id", sourceLocation: sourceLocation)
            #expect(recorder.callCount == 0, "the signer provider must not be consulted", sourceLocation: sourceLocation)
            #expect((requests.value ?? []).isEmpty, "no request may reach the network", sourceLocation: sourceLocation)
        } catch {
            Issue.record("Expected FeedbackClientError, got \(error)", sourceLocation: sourceLocation)
        }
    }
}

// MARK: - Plan bounds

extension UserAttributeValueBoundsTests {

    @Test func updateUserAttributesRejectsEmptyPlanBeforeSigning() async throws {
        let requests = Self.recordRequests()
        let (client, recorder) = Self.makeFullySignedClient()
        await assertRejectedBeforeSigning(recording: requests, recorder: recorder, attribute: "plan") {
            try await client.updateUserAttributes(plan: "", userToken: "user-uuid-empty-plan")
        }
    }

    @Test func updateUserAttributesRejectsPlanOver64CodePointsBeforeSigning() async throws {
        let requests = Self.recordRequests()
        let (client, recorder) = Self.makeFullySignedClient()
        // 65 ASCII code points.
        await assertRejectedBeforeSigning(recording: requests, recorder: recorder, attribute: "plan") {
            try await client.updateUserAttributes(plan: String(repeating: "a", count: 65), userToken: "user-uuid-long-plan")
        }
        // 33 decomposed `é` units: 33 grapheme clusters (a grapheme counter
        // would accept this) but 66 Unicode code points — the unit the
        // server counts. Pins the counting convention of #578.
        await assertRejectedBeforeSigning(recording: requests, recorder: recorder, attribute: "plan") {
            try await client.updateUserAttributes(
                plan: String(repeating: "e\u{0301}", count: 33),
                userToken: "user-uuid-long-plan-marks"
            )
        }
    }

    @Test func updateUserAttributesAcceptsPlanAtBothBounds() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(), try encodeJSON(["ok": true, "updatedAt": "2026-10-26T00:00:00.000Z"]))
        }
        let (client, _) = Self.makeFullySignedClient()

        // Exactly one code point.
        _ = try await client.updateUserAttributes(plan: "a", userToken: "user-uuid-min-plan")
        // Exactly 64 code points (32 decomposed `é`) — the cap is inclusive
        // and counted in code points, not grapheme clusters.
        _ = try await client.updateUserAttributes(
            plan: String(repeating: "e\u{0301}", count: 32),
            userToken: "user-uuid-max-plan"
        )
    }

    @Test func whitespaceOnlyPlanKeepsServerSideVerdict() async throws {
        // The server's `min(1)` accepts whitespace-only strings and never
        // trims, so the local gate must not trim either: a single space is
        // signed and sent verbatim.
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["ok": true, "updatedAt": "2026-10-26T00:00:00.000Z"]))
        }
        let (client, _) = Self.makeFullySignedClient()

        _ = try await client.updateUserAttributes(plan: " ", userToken: "user-uuid-space-plan")

        let request = try #require(capture.value)
        let rawData = try #require(bodyData(from: request))
        let json = try #require(parseJSONDict(rawData))
        #expect(json["plan"] as? String == " ")
    }
}

// MARK: - MRR bounds

extension UserAttributeValueBoundsTests {

    @Test func updateUserAttributesRejectsNegativeMRRBeforeSigning() async throws {
        let requests = Self.recordRequests()
        let (client, recorder) = Self.makeFullySignedClient()
        await assertRejectedBeforeSigning(recording: requests, recorder: recorder, attribute: "mrr") {
            try await client.updateUserAttributes(mrr: -0.01, userToken: "user-uuid-negative-mrr")
        }
    }

    @Test func updateUserAttributesRejectsMRRAboveOneMillionBeforeSigning() async throws {
        let requests = Self.recordRequests()
        let (client, recorder) = Self.makeFullySignedClient()
        await assertRejectedBeforeSigning(recording: requests, recorder: recorder, attribute: "mrr") {
            try await client.updateUserAttributes(mrr: 1_000_000.01, userToken: "user-uuid-huge-mrr")
        }
    }

    @Test func updateUserAttributesAcceptsMRRAtBothBounds() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(), try encodeJSON(["ok": true, "updatedAt": "2026-10-26T00:00:00.000Z"]))
        }
        let (client, _) = Self.makeFullySignedClient()

        _ = try await client.updateUserAttributes(mrr: 0, userToken: "user-uuid-zero-mrr")
        _ = try await client.updateUserAttributes(mrr: 1_000_000, userToken: "user-uuid-cap-mrr")
    }

    @Test func nonFiniteMRRStillCoercesToZeroOnTheWire() async throws {
        // The SEC-3 coercion is unchanged by the bounds gate: NaN/infinity
        // are checked (and sent) as `0`, which sits on the accepted floor.
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["ok": true, "updatedAt": "2026-10-26T00:00:00.000Z"]))
        }
        let (client, recorder) = Self.makeFullySignedClient()

        _ = try await client.updateUserAttributes(mrr: .nan, userToken: "user-uuid-nan-mrr")
        let nanRequest = try #require(capture.value)
        let nanData = try #require(bodyData(from: nanRequest))
        let nanJSON = try #require(parseJSONDict(nanData))
        #expect(nanJSON["mrr"] as? Double == 0)

        capture.value = nil
        _ = try await client.updateUserAttributes(mrr: .infinity, userToken: "user-uuid-inf-mrr")
        let infRequest = try #require(capture.value)
        let infData = try #require(bodyData(from: infRequest))
        let infJSON = try #require(parseJSONDict(infData))
        #expect(infJSON["mrr"] as? Double == 0)
        #expect(recorder.callCount == 2, "finite-coerced values sign normally")
    }
}

// MARK: - Currency bounds

extension UserAttributeValueBoundsTests {

    @Test func updateUserAttributesRejectsMalformedCurrencyBeforeSigning() async throws {
        let requests = Self.recordRequests()
        let (client, recorder) = Self.makeFullySignedClient()
        for currency in ["US", "US1", "$", "usd ", "€", "USDd"] {
            await assertRejectedBeforeSigning(recording: requests, recorder: recorder, attribute: "currency") {
                try await client.updateUserAttributes(currency: currency, userToken: "user-uuid-bad-currency")
            }
        }
    }

    @Test func updateUserAttributesAcceptsLowercaseCurrencySigningTheRawValue() async throws {
        // The server validates `^[A-Za-z]{3}$` and uppercases after, and the
        // signature covers the raw value as sent — so lowercase passes the
        // gate and reaches the wire verbatim. The embedded secret signs this
        // report (no provider installed), so the signature assertion below
        // pins that the canonical string carries the raw lowercase value.
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["ok": true, "updatedAt": "2026-10-26T00:00:00.000Z"]))
        }
        let client = makeClient(
            baseURL: URL(string: "https://\(Self.apiHost)")!,
            appKey: Self.testAppKey,
            signingSecret: Self.testSecret
        )
        let token = "user-uuid-lowercase-currency"
        let fixedTimestamp: Int64 = 1_773_600_000

        _ = try await client.updateUserAttributes(
            isPaying: true,
            mrr: 49.0,
            currency: "usd",
            userToken: token,
            signingSecret: Self.testSecret,
            timestamp: fixedTimestamp
        )

        let request = try #require(capture.value)
        let rawData = try #require(bodyData(from: request))
        let json = try #require(parseJSONDict(rawData))
        #expect(json["currency"] as? String == "usd", "currency must be sent as given, never uppercased locally")
        let signature = try #require(json["signature"] as? String)
        let expectedCanonical = UserAttributesSigner.canonicalString(
            for: .init(
                appKey: Self.testAppKey,
                userToken: token,
                isPaying: .value(true),
                mrr: .value(49.0),
                currency: .value("usd"),
                timestamp: fixedTimestamp
            )
        )
        #expect(signature == UserAttributesSigner.signature(for: expectedCanonical, secret: Self.testSecret))
    }
}

// MARK: - Nullability semantics unchanged (issue #573)

extension UserAttributeValueBoundsTests {

    @Test func clearsAndUnsetsAreNotBoundsChecked() async throws {
        // `.null` and `.unset` keep their #573 semantics: only `.value`
        // fields are bounds-checked, so a clearing report signs and sends
        // exactly as before #607.
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["ok": true, "updatedAt": "2026-10-26T00:00:00.000Z"]))
        }
        let (client, recorder) = Self.makeFullySignedClient()

        _ = try await client.updateUserAttributes(
            isPaying: .value(false),
            plan: .null,
            mrr: .null,
            currency: .unset,
            userToken: "user-uuid-clears-unchanged"
        )

        let request = try #require(capture.value)
        let rawData = try #require(bodyData(from: request))
        let json = try #require(parseJSONDict(rawData))
        #expect(json["plan"] is NSNull)
        #expect(json["mrr"] is NSNull)
        #expect(json["signature"] != nil)
        #expect(recorder.callCount == 1)
    }
}

// MARK: - User-facing copy

extension UserAttributeValueBoundsTests {

    @Test func invalidAttributeValueRendersCuratedCopyWithoutServerText() {
        let local = FeedbackClientError.invalidAttributeValue(attribute: "plan", message: nil, requestId: nil)
        #expect(local.errorDescription == CupThreadStrings.tr("cupthread.error.attribute_invalid"))
        #expect(!local.errorDescription!.contains("request id"))

        let server = FeedbackClientError.invalidAttributeValue(
            attribute: "mrr",
            message: "Validation failed",
            requestId: "req-607"
        )
        #expect(
            server.errorDescription
                == CupThreadStrings.tr("cupthread.error.attribute_invalid") + " (request id: req-607)"
        )
        #expect(!server.errorDescription!.contains("Validation failed"), "raw server text stays off user copy")
        #expect(server.responseBody == nil, "raw server text stays off responseBody")
        #expect(server.requestId == "req-607")
    }
}
