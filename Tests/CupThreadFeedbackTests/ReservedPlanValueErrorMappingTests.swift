import Foundation
import Testing
@testable import CupThreadFeedback

// Issue #403 (SaaS PR #794): the DATA-03 canonical string renders an absent
// `plan` as `unset` and an explicit JSON null as `null`, so a developer-supplied
// plan equal to either byte-exact literal would be indistinguishable from the
// sentinel semantics inside the signed payload. The server now reserves both and
// rejects the report before signature verification with HTTP 400 and the field
// error `plan_reserved_sentinel`. The SDK must surface the rejection as a typed,
// non-retried validation error.
@Suite("ReservedPlanValue Error Mapping", .serialized)
struct ReservedPlanValueErrorMappingTests {
    static let apiHost = "reserved-plan.example.com"
    static let testSecret = "sec_reserved_plan_secret"

    static func makeSigningClient() -> FeedbackClient {
        makeClient(
            baseURL: URL(string: "https://\(apiHost)")!,
            signingSecret: testSecret
        )
    }
}

/// Thread-safe request counter for retry-semantics assertions.
private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

// MARK: - Wire mapping

extension ReservedPlanValueErrorMappingTests {

    @Test func updateUserAttributesMapsPlanReservedSentinelFieldErrorToTypedError() async throws {
        let counter = RequestCounter()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            counter.increment()
            return (
                makeHTTPResponse(status: 400, headers: ["X-Request-Id": "req-400-reserved"]),
                try encodeJSON([
                    "error": "Validation failed",
                    "details": ["fieldErrors": ["plan": ["plan_reserved_sentinel"]]]
                ])
            )
        }

        do {
            _ = try await Self.makeSigningClient().updateUserAttributes(
                plan: .value("unset"),
                userToken: "token-403"
            )
            Issue.record("Expected reservedPlanValue")
        } catch let error as FeedbackClientError {
            guard case .reservedPlanValue(let message, let requestId) = error else {
                Issue.record("Expected .reservedPlanValue, got \(error)")
                return
            }
            #expect(message == "Validation failed")
            #expect(requestId == "req-400-reserved")
            #expect(error.requestId == "req-400-reserved")
            #expect(error.responseBody == nil, "raw server text must stay off responseBody")
            #expect(counter.value == 1, "a reserved-plan rejection is a normal validation error and must never be retried")
        }
    }

    @Test func planReservedSentinelWithoutRequestId() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 400),
                try encodeJSON([
                    "error": "Validation failed",
                    "details": ["fieldErrors": ["plan": ["plan_reserved_sentinel"]]]
                ])
            )
        }

        do {
            _ = try await Self.makeSigningClient().updateUserAttributes(
                plan: .value("null"),
                userToken: "token-403"
            )
            Issue.record("Expected reservedPlanValue")
        } catch let error as FeedbackClientError {
            guard case .reservedPlanValue(_, let requestId) = error else {
                Issue.record("Expected .reservedPlanValue, got \(error)")
                return
            }
            #expect(requestId == nil)
            #expect(error.requestId == nil)
        }
    }

    @Test func otherPlanFieldErrorsStayUnexpectedStatus() async throws {
        // Only the documented `plan_reserved_sentinel` field error maps to the
        // typed error; every other plan validation issue keeps the diagnostic
        // unexpectedStatus.
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 400, headers: ["X-Request-Id": "req-400-other"]),
                try encodeJSON([
                    "error": "Validation failed",
                    "details": ["fieldErrors": ["plan": ["too_long"]]]
                ])
            )
        }

        do {
            _ = try await Self.makeSigningClient().updateUserAttributes(
                plan: .value("way-too-long-plan-name"),
                userToken: "token-403"
            )
            Issue.record("Expected unexpectedStatus")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, _, let requestId) = error else {
                Issue.record("Expected unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 400)
            #expect(requestId == "req-400-other")
        }
    }

    @Test func sentinelUnderAnotherFieldDoesNotMapToReservedPlanValue() async throws {
        // The reservation applies to `plan` only; a sentinel-looking message on
        // any other field is not a reserved-plan rejection.
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 400),
                try encodeJSON([
                    "error": "Validation failed",
                    "details": ["fieldErrors": ["currency": ["plan_reserved_sentinel"]]]
                ])
            )
        }

        do {
            _ = try await Self.makeSigningClient().updateUserAttributes(
                currency: .value("USD"),
                userToken: "token-403"
            )
            Issue.record("Expected unexpectedStatus")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, _, _) = error else {
                Issue.record("Expected unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 400)
        }
    }

    @Test func sentinelMessageMatchIsByteExact() async throws {
        // The reservation is byte-exact on the server (case-sensitive,
        // whole-string), so the SDK mapping must not widen it.
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 400),
                try encodeJSON([
                    "error": "Validation failed",
                    "details": ["fieldErrors": ["plan": ["PLAN_RESERVED_SENTINEL"]]]
                ])
            )
        }

        do {
            _ = try await Self.makeSigningClient().updateUserAttributes(
                plan: .value("unset"),
                userToken: "token-403"
            )
            Issue.record("Expected unexpectedStatus")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, _, _) = error else {
                Issue.record("Expected unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 400)
        }
    }

    // MARK: - Near-miss plan values remain sendable

    @Test func nearMissPlanNamesAreSentUnchangedAndSucceed() async throws {
        for plan in ["UNSET", "Unset", "unsettled", "nullify", "null-safe"] {
            let capture = CaptureBox<URLRequest>()
            MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
                capture.value = request
                return (makeHTTPResponse(), try encodeJSON(["ok": true, "updatedAt": "2026-10-12T00:00:00.000Z"]))
            }

            let result = try await Self.makeSigningClient().updateUserAttributes(
                plan: .value(plan),
                userToken: "token-403-near-miss"
            )

            #expect(result.ok == true)
            let request = try #require(capture.value)
            let rawData = try #require(bodyData(from: request))
            let json = try #require(parseJSONDict(rawData))
            #expect(json["plan"] as? String == plan, "near-miss plan must reach the wire unchanged")
        }
    }

    // MARK: - Why the literals are reserved (canonical-string collision)

    @Test func canonicalStringRendersReservedLiteralsByteIdenticallyToSentinels() {
        // The collision that motivated the server reservation (#403): a plan
        // value of "unset" signs the same canonical line as an absent plan,
        // and "null" the same line as an explicit JSON null.
        func canonical(plan: UserAttributesSigner.Field<String>) -> String {
            UserAttributesSigner.canonicalString(
                for: .init(appKey: "app", userToken: "user", plan: plan, timestamp: 1_773_600_000)
            )
        }
        #expect(canonical(plan: .value("unset")) == canonical(plan: .unset))
        #expect(canonical(plan: .value("null")) == canonical(plan: .null))
        #expect(canonical(plan: .unset) != canonical(plan: .null))
    }

    // MARK: - Envelope decoding

    @Test func errorEnvelopeDecodesFieldErrorDetails() throws {
        let data = try encodeJSON([
            "error": "Validation failed",
            "details": ["fieldErrors": ["plan": ["plan_reserved_sentinel"]]]
        ])
        let envelope = try JSONDecoder().decode(APIErrorEnvelope.self, from: data)
        #expect(envelope.error == "Validation failed")
        #expect(envelope.code == nil)
        #expect(envelope.details?.fieldErrors?["plan"] == ["plan_reserved_sentinel"])
    }

    @Test func errorEnvelopeWithoutDetailsDecodes() throws {
        let data = try encodeJSON(["error": "Conflict", "code": "already_finalized"])
        let envelope = try JSONDecoder().decode(APIErrorEnvelope.self, from: data)
        #expect(envelope.error == "Conflict")
        #expect(envelope.code == "already_finalized")
        #expect(envelope.details == nil)
    }

    // MARK: - User-facing copy

    @Test func reservedPlanValueRendersCuratedCopyWithoutServerText() {
        let error = FeedbackClientError.reservedPlanValue(
            message: "Validation failed",
            requestId: "req-res-1"
        )
        let expected = CupThreadStrings.tr("cupthread.error.reserved_plan_value") + " (request id: req-res-1)"
        #expect(error.errorDescription == expected)
        #expect(!error.errorDescription!.contains("Validation failed"))
    }

    @Test func reservedPlanValueDescriptionOmitsRequestIdWhenAbsent() throws {
        let error = FeedbackClientError.reservedPlanValue(message: "details", requestId: nil)
        let desc = try #require(error.errorDescription)
        #expect(desc == CupThreadStrings.tr("cupthread.error.reserved_plan_value"))
        #expect(!desc.contains("request id"))
        #expect(!desc.contains("cupthread.error.reserved_plan_value"))
    }
}
