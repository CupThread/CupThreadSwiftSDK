import Foundation
import Testing
@testable import CupThreadFeedback

// Issue #606: the two Turnstile-gated intake paths that carry an email
// address — `FeedbackClient.submit` (`FeedbackDraft.reporterEmail`) and
// `FeedbackClient.castVote(shipNotifyEmail:)` — put the address on the wire
// with no shape check, so a malformed address consulted the Turnstile
// provider first (burning a single-use challenge on the vote path, #493) and
// the server's field-level `400` surfaced as generic request-failed copy.
// Both paths now apply the same local `EmailShape` gate `subscribeToChangelog`
// has applied since #419, and a residual server `400` whose field errors name
// an email field maps to the same typed error, with the response's request id.
@Suite("Intake Email Shape Gate", .serialized)
struct IntakeEmailShapeGateTests {
    static let apiHost = "intake-email-gate.example.com"

    /// Thread-safe counter recording every Turnstile provider consultation.
    final class ProviderCallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0

        func record() -> String? {
            lock.lock()
            defer { lock.unlock() }
            calls += 1
            return "turnstile-token"
        }

        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }

    /// A client whose Turnstile provider and network host both record every
    /// consultation, so a local rejection can prove neither was reached.
    static func makeCountingClient() -> (FeedbackClient, ProviderCallCounter) {
        let counter = ProviderCallCounter()
        let client = FeedbackClient(
            configuration: FeedbackClientConfiguration(
                baseURL: URL(string: "https://\(apiHost)")!,
                appKey: "app_emailgate12345"
            ),
            session: makeMockSession(),
            turnstileTokenProvider: { _ in counter.record() }
        )
        return (client, counter)
    }

    static func feedbackSuccessHandler() -> CaptureBox<URLRequest> {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["submissionId": "s-1", "forwardedToGithub": false]))
        }
        return capture
    }

    static func voteSuccessHandler() -> CaptureBox<URLRequest> {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["voted": true, "voteCount": 3]))
        }
        return capture
    }

    static func validDraft(reporterEmail: String) -> FeedbackDraft {
        FeedbackDraft(
            title: "Valid title",
            description: "Valid description",
            reporterEmail: reporterEmail,
            platform: .ios
        )
    }

    // MARK: - submit (reporterEmail)

    @Test("submit rejects implausible reporterEmail locally with no Turnstile consultation and no network call")
    func submitRejectsImplausibleReporterEmailLocally() async throws {
        let capture = Self.feedbackSuccessHandler()
        defer { MockURLProtocol.setHandler(forHost: Self.apiHost, nil) }
        let implausibleEmails = [
            "not-an-email",
            "user@localhost",
            "foo@",
            "a b@example.com",
            "user@@example.com",
            "user@example..com"
        ]

        for email in implausibleEmails {
            let (client, counter) = Self.makeCountingClient()
            await #expect(throws: FeedbackClientError.invalidEmailAddress(field: "reporterEmail", requestId: nil)) {
                _ = try await client.submit(Self.validDraft(reporterEmail: email), userToken: "token-606")
            }
            #expect(counter.callCount == 0, "'\(email)' must never consume a Turnstile token")
        }
        #expect(capture.value == nil, "An implausible address must be rejected before any request is sent")
    }

    @Test("submit still sends plausible reporterEmail and omits blank values exactly as before")
    func submitKeepsPlausibleAndBlankReporterEmailBehavior() async throws {
        let capture = Self.feedbackSuccessHandler()
        defer { MockURLProtocol.setHandler(forHost: Self.apiHost, nil) }
        let (client, counter) = Self.makeCountingClient()

        // A plausible address reaches the wire trimmed and unchanged — the
        // gate must not over-tighten past what the server accepts (#419).
        _ = try await client.submit(Self.validDraft(reporterEmail: " first.last+tag@sub.example.co.uk "), userToken: "token-606")
        var sentRequest = try #require(capture.value)
        var sentBody = try #require(bodyData(from: sentRequest))
        var json = try #require(parseJSONDict(sentBody))
        #expect(json["reporterEmail"] as? String == "first.last+tag@sub.example.co.uk")
        #expect(counter.callCount == 1)

        // A whitespace-only address keeps its field-omitted semantics.
        _ = try await client.submit(Self.validDraft(reporterEmail: "   "), userToken: "token-606")
        sentRequest = try #require(capture.value)
        sentBody = try #require(bodyData(from: sentRequest))
        json = try #require(parseJSONDict(sentBody))
        #expect(json["reporterEmail"] == nil)
        #expect(counter.callCount == 2)
    }

    @Test("an over-cap reporterEmail keeps answering textTooLong from the caps gate")
    func submitOverCapReporterEmailStaysTextTooLong() async throws {
        let capture = Self.feedbackSuccessHandler()
        defer { MockURLProtocol.setHandler(forHost: Self.apiHost, nil) }
        let (client, counter) = Self.makeCountingClient()

        let overCap = String(repeating: "a", count: 300) + "@example.com"
        await #expect(throws: FeedbackClientError.textTooLong) {
            _ = try await client.submit(Self.validDraft(reporterEmail: overCap), userToken: "token-606")
        }
        #expect(counter.callCount == 0)
        #expect(capture.value == nil)
    }

    // MARK: - castVote (shipNotifyEmail)

    @Test("castVote rejects implausible shipNotifyEmail locally with no Turnstile consultation and no network call")
    func castVoteRejectsImplausibleShipNotifyEmailLocally() async throws {
        let capture = Self.voteSuccessHandler()
        defer { MockURLProtocol.setHandler(forHost: Self.apiHost, nil) }
        let implausibleEmails = ["not-an-email", "user@localhost", "foo@"]

        for email in implausibleEmails {
            let (client, counter) = Self.makeCountingClient()
            await #expect(throws: FeedbackClientError.invalidEmailAddress(field: "shipNotifyEmail", requestId: nil)) {
                _ = try await client.castVote(
                    featureRequestId: "fr-606",
                    userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f",
                    shipNotifyEmail: email
                )
            }
            #expect(counter.callCount == 0, "'\(email)' must never consume a ship-notify Turnstile token")
        }
        #expect(capture.value == nil, "An implausible opt-in address must be rejected before any request is sent")
    }

    @Test("castVote rejects a shipNotifyEmail over the documented 254-code-point cap")
    func castVoteRejectsOverlongShipNotifyEmail() async throws {
        let capture = Self.voteSuccessHandler()
        defer { MockURLProtocol.setHandler(forHost: Self.apiHost, nil) }
        let (client, counter) = Self.makeCountingClient()

        // One code point past the documented cap; plausible in shape, so only
        // the length gate can catch it.
        let over = String(repeating: "a", count: 243) + "@example.com"
        #expect(IntakeTextLimits.measuredLength(over) == 255)
        await #expect(throws: FeedbackClientError.invalidEmailAddress(field: "shipNotifyEmail", requestId: nil)) {
            _ = try await client.castVote(
                featureRequestId: "fr-606",
                userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f",
                shipNotifyEmail: over
            )
        }
        #expect(counter.callCount == 0)
        #expect(capture.value == nil)

        // Exactly at the cap the address rides the wire unchanged.
        let atCap = String(repeating: "a", count: 242) + "@example.com"
        #expect(IntakeTextLimits.measuredLength(atCap) == 254)
        _ = try await client.castVote(
            featureRequestId: "fr-606",
            userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f",
            shipNotifyEmail: atCap
        )
        let sentRequest = try #require(capture.value)
        let sentBody = try #require(bodyData(from: sentRequest))
        let json = try #require(parseJSONDict(sentBody))
        #expect(json["shipNotifyEmail"] as? String == atCap)
    }

    @Test("a plain vote without shipNotifyEmail is unaffected by the gate")
    func castVoteWithoutShipNotifyEmailIsUnaffected() async throws {
        let capture = Self.voteSuccessHandler()
        defer { MockURLProtocol.setHandler(forHost: Self.apiHost, nil) }
        let (client, counter) = Self.makeCountingClient()

        let result = try await client.castVote(featureRequestId: "fr-606", userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f")
        #expect(result.voted == true)
        #expect(counter.callCount == 1)
        let sentRequest = try #require(capture.value)
        let sentBody = try #require(bodyData(from: sentRequest))
        let json = try #require(parseJSONDict(sentBody))
        #expect(json["shipNotifyEmail"] == nil)
    }

    // MARK: - Residual server field-error 400s

    @Test("a server 400 naming reporterEmail maps to the typed error with the response's request id")
    func serverFieldErrorForReporterEmailMapsToTypedError() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (
                makeHTTPResponse(status: 400, headers: ["X-Request-Id": "req-abc12345"]),
                try encodeJSON([
                    "error": "Validation failed",
                    "details": ["fieldErrors": ["reporterEmail": ["Invalid email address"]]]
                ])
            )
        }
        defer { MockURLProtocol.setHandler(forHost: Self.apiHost, nil) }
        // No Turnstile provider: the residual 400 must surface on the first
        // attempt, not be retried or masked as unexpectedStatus.
        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!)

        await #expect(throws: FeedbackClientError.invalidEmailAddress(field: "reporterEmail", requestId: "req-abc12345")) {
            _ = try await client.submit(Self.validDraft(reporterEmail: "user@my_host.com"), userToken: "token-606")
        }
        #expect(capture.value != nil, "The edge-case address is the server's to judge: it must reach the wire")
    }

    @Test("a server 400 naming shipNotifyEmail maps to the typed error with the response's request id")
    func serverFieldErrorForShipNotifyEmailMapsToTypedError() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 400, headers: ["X-Request-Id": "req-def67890"]),
                try encodeJSON([
                    "error": "Validation failed",
                    "details": ["fieldErrors": ["shipNotifyEmail": ["Invalid email address"]]]
                ])
            )
        }
        defer { MockURLProtocol.setHandler(forHost: Self.apiHost, nil) }
        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!)

        await #expect(throws: FeedbackClientError.invalidEmailAddress(field: "shipNotifyEmail", requestId: "req-def67890")) {
            _ = try await client.castVote(
                featureRequestId: "fr-606",
                userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f",
                shipNotifyEmail: "user@my_host.com"
            )
        }
    }

    @Test("a server 400 naming unrelated fields keeps the existing mapping")
    func serverFieldErrorForOtherFieldsIsUnchanged() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 400, headers: ["X-Request-Id": "req-ghi13579"]),
                try encodeJSON([
                    "error": "Validation failed",
                    "details": ["fieldErrors": ["title": ["String must contain at least 3 character(s)"]]]
                ])
            )
        }
        defer { MockURLProtocol.setHandler(forHost: Self.apiHost, nil) }
        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!)

        await #expect(throws: FeedbackClientError.unexpectedStatus(
            code: 400,
            message: "Validation failed",
            requestId: "req-ghi13579"
        )) {
            _ = try await client.submit(Self.validDraft(reporterEmail: "user@example.com"), userToken: "token-606")
        }
    }

    // MARK: - Error plumbing

    @Test("the typed error carries its request id and the convenience constructor marks local rejections")
    func typedErrorRequestIdPlumbing() {
        #expect(
            FeedbackClientError.invalidEmailAddress(field: "reporterEmail", requestId: "req-abc12345").requestId
                == "req-abc12345"
        )
        #expect(FeedbackClientError.invalidEmailAddress(field: "reporterEmail").requestId == nil)
        #expect(
            FeedbackClientError.invalidEmailAddress(field: "shipNotifyEmail")
                == FeedbackClientError.invalidEmailAddress(field: "shipNotifyEmail", requestId: nil)
        )
        #expect(FeedbackClientError.invalidEmailAddress(field: "reporterEmail").responseBody == nil)
    }
}
