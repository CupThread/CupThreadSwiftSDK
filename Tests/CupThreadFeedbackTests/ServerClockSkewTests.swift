import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - ServerClock unit tests

/// The learned server-clock offset (API-19): RFC 1123 parsing, offset
/// application, and latest-observation-wins semantics.
@Suite("ServerClock")
struct ServerClockTests {
    private static func makeHTTPDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.string(from: date)
    }

    @Test func httpDateParsesRFC1123Fixdate() {
        let parsed = ServerClock.httpDate("Thu, 01 Jan 2026 00:00:00 GMT")
        #expect(parsed == Date(timeIntervalSince1970: 1_767_225_600))
    }

    @Test func httpDateRoundTrips() {
        let date = Date(timeIntervalSince1970: 1_790_000_030)
        #expect(ServerClock.httpDate(Self.makeHTTPDateString(date)) == date)
    }

    @Test func httpDateRejectsGarbage() {
        #expect(ServerClock.httpDate("not a date") == nil)
        #expect(ServerClock.httpDate("") == nil)
    }

    @Test func correctedNowMatchesDeviceClockBeforeObservation() {
        let deviceNow = Date(timeIntervalSince1970: 1_790_000_000)
        let clock = ServerClock(now: { deviceNow })
        #expect(clock.hasObservation == false)
        #expect(clock.correctedNow() == deviceNow)
    }

    @Test func correctedNowAppliesOffsetAndLatestObservationWins() {
        let deviceNow = Date(timeIntervalSince1970: 1_790_000_000)
        let clock = ServerClock(now: { deviceNow })
        clock.record(serverDate: deviceNow.addingTimeInterval(90))
        #expect(clock.hasObservation == true)
        #expect(clock.correctedNow() == deviceNow.addingTimeInterval(90))
        clock.record(serverDate: deviceNow.addingTimeInterval(50))
        #expect(clock.correctedNow() == deviceNow.addingTimeInterval(50))
    }

    @Test func negativeOffsetCorrectsAheadSkew() {
        let deviceNow = Date(timeIntervalSince1970: 1_790_000_600)
        let clock = ServerClock(now: { deviceNow })
        clock.record(serverDate: Date(timeIntervalSince1970: 1_790_000_030))
        #expect(clock.correctedNow() == Date(timeIntervalSince1970: 1_790_000_030))
    }
}

// MARK: - Clock-skew recovery on signed PUT /user (issue #279 / API-19)

/// Payment-attribute signing survives a skewed device clock: the client
/// signs with the server-time offset learned from response `Date` headers,
/// and a `401 stale_signature` rejection is recovered exactly once by
/// re-signing with the refreshed offset.
@Suite("UserAttributesClockSkew", .serialized)
struct UserAttributesClockSkewTests {
    static let apiHost = "server-clock-skew.example.com"
    static let secret = "sec_clock_skew_secret"
    static let appKey = "app_clockskew123456"
    /// The server's real time in these scenarios.
    static let baseEpoch: Int64 = 1_790_000_030
    /// The device clock in these scenarios runs +10 minutes ahead.
    static let deviceSkewSeconds: Int64 = 600

    static func makeSkewedClient() -> FeedbackClient {
        makeClient(
            baseURL: URL(string: "https://\(apiHost)")!,
            appKey: appKey,
            signingSecret: secret,
            serverClock: ServerClock(now: {
                Date(timeIntervalSince1970: TimeInterval(baseEpoch + deviceSkewSeconds))
            })
        )
    }

    static func makeOnTimeClient() -> FeedbackClient {
        makeClient(
            baseURL: URL(string: "https://\(apiHost)")!,
            appKey: appKey,
            signingSecret: secret,
            serverClock: ServerClock(now: { Date(timeIntervalSince1970: TimeInterval(baseEpoch)) })
        )
    }

    private static func makeHTTPDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.string(from: date)
    }

    private static func serverDateHeader(secondsAfterBase: Int64 = 0) -> String {
        makeHTTPDateString(Date(timeIntervalSince1970: TimeInterval(baseEpoch + secondsAfterBase)))
    }

    private static func staleSignatureResponse(dateHeader: String) throws -> (HTTPURLResponse, Data) {
        (
            makeHTTPResponse(
                status: 401,
                headers: ["Date": dateHeader, "X-Request-Id": "req-stale"]
            ),
            try encodeJSON(["error": "Stale signature", "code": "stale_signature"])
        )
    }

    /// Installs a handler that records every request and answers each with
    /// the given responder (invoked with the 1-based attempt number).
    private static func installRecordingHandler(
        capturing requests: CaptureBox<[URLRequest]>,
        _ responder: @escaping (Int) throws -> (HTTPURLResponse, Data)
    ) {
        MockURLProtocol.setHandler(forHost: apiHost) { request in
            requests.value?.append(request)
            let attempt = requests.value?.count ?? 0
            return try responder(attempt)
        }
    }

    private static func successResponse() throws -> (HTTPURLResponse, Data) {
        (
            makeHTTPResponse(headers: ["Date": serverDateHeader()]),
            try encodeJSON(["ok": true, "updatedAt": "2026-10-07T00:00:00.000Z"])
        )
    }

    @Test func responseDateHeaderTeachesTheSigningClock() async throws {
        // The server runs +120 s ahead of the device clock in this scenario.
        let requests = CaptureBox<[URLRequest]>()
        requests.value = []
        Self.installRecordingHandler(capturing: requests) { attempt in
            if attempt == 1 {
                return (
                    makeHTTPResponse(headers: ["Date": Self.serverDateHeader(secondsAfterBase: 120)]),
                    try encodeJSON(["ok": true, "updatedAt": "2026-10-07T00:00:00.000Z"])
                )
            }
            return try Self.successResponse()
        }

        let client = Self.makeOnTimeClient()
        // An unsigned call learns the offset from the response's `Date` header.
        _ = try await client.updateUserAttributes(userToken: "user-clock-learn")
        // The next signed call signs with the corrected clock, not the device clock.
        _ = try await client.updateUserAttributes(isPaying: true, userToken: "user-clock-learn")

        let sent = try #require(requests.value)
        #expect(sent.count == 2)
        let rawData = try #require(bodyData(from: sent[1]))
        let signedBody = try #require(parseJSONDict(rawData))
        let timestamp = try #require(signedBody["timestamp"] as? Int64)
        #expect(timestamp == Self.baseEpoch + 120)

        let expectedSignature = UserAttributesSigner.signature(
            for: UserAttributesSigner.canonicalString(
                for: .init(
                    appKey: Self.appKey,
                    userToken: "user-clock-learn",
                    isPaying: .value(true),
                    timestamp: Self.baseEpoch + 120
                )
            ),
            secret: Self.secret
        )
        #expect(signedBody["signature"] as? String == expectedSignature)
    }

    @Test func staleSignatureIsRecoveredOnceWithTheCorrectedClock() async throws {
        let requests = CaptureBox<[URLRequest]>()
        requests.value = []
        Self.installRecordingHandler(capturing: requests) { attempt in
            if attempt == 1 {
                return try Self.staleSignatureResponse(dateHeader: Self.serverDateHeader())
            }
            return try Self.successResponse()
        }

        let client = Self.makeSkewedClient()
        let result = try await client.updateUserAttributes(
            isPaying: true,
            plan: "pro",
            mrr: 42,
            userToken: "user-clock-skew"
        )

        // Exactly two requests: the stale attempt and the single recovery.
        let sent = try #require(requests.value)
        #expect(sent.count == 2)
        #expect(result.ok == true)

        // First attempt: signed with the raw skewed device clock — 600 s
        // ahead of the server's `Date`, outside the ±300 s freshness window.
        let firstData = try #require(bodyData(from: sent[0]))
        let firstBody = try #require(parseJSONDict(firstData))
        #expect(firstBody["timestamp"] as? Int64 == Self.baseEpoch + Self.deviceSkewSeconds)

        // Recovery: re-signed with the offset learned from the failing
        // response's `Date` header — exactly the server's time.
        let secondData = try #require(bodyData(from: sent[1]))
        let secondBody = try #require(parseJSONDict(secondData))
        let retryTimestamp = try #require(secondBody["timestamp"] as? Int64)
        #expect(retryTimestamp == Self.baseEpoch)
        #expect(abs(retryTimestamp - Self.baseEpoch) <= 300)

        let expectedRetrySignature = UserAttributesSigner.signature(
            for: UserAttributesSigner.canonicalString(
                for: .init(
                    appKey: Self.appKey,
                    userToken: "user-clock-skew",
                    isPaying: .value(true),
                    plan: .value("pro"),
                    mrr: .value(42),
                    timestamp: retryTimestamp
                )
            ),
            secret: Self.secret
        )
        #expect(secondBody["signature"] as? String == expectedRetrySignature)
    }

    @Test func invalidSignatureIsNeverRetried() async throws {
        let requests = CaptureBox<[URLRequest]>()
        requests.value = []
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            requests.value?.append(request)
            return (
                makeHTTPResponse(
                    status: 401,
                    headers: ["Date": Self.serverDateHeader(), "X-Request-Id": "req-invalid"]
                ),
                try encodeJSON(["error": "Invalid signature", "code": "invalid_signature"])
            )
        }

        let client = Self.makeSkewedClient()
        do {
            _ = try await client.updateUserAttributes(isPaying: true, userToken: "user-clock-skew")
            Issue.record("Expected invalidSignature error")
        } catch let error as FeedbackClientError {
            guard case .invalidSignature = error else {
                Issue.record("Expected .invalidSignature, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
        // A mismatched secret is not a clock problem: exactly one request.
        #expect(requests.value?.count == 1)
    }

    @Test func staleSignatureRetriedExactlyOnceThenSurfaces() async throws {
        let requests = CaptureBox<[URLRequest]>()
        requests.value = []
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            requests.value?.append(request)
            return try Self.staleSignatureResponse(dateHeader: Self.serverDateHeader())
        }

        let client = Self.makeSkewedClient()
        do {
            _ = try await client.updateUserAttributes(isPaying: true, userToken: "user-clock-skew")
            Issue.record("Expected staleSignature error")
        } catch let error as FeedbackClientError {
            guard case .staleSignature = error else {
                Issue.record("Expected .staleSignature, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
        // The recovery attempt happened and failed again: exactly two requests.
        #expect(requests.value?.count == 2)
    }

    @Test func nonSignature401IsNotRetried() async throws {
        let requests = CaptureBox<[URLRequest]>()
        requests.value = []
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            requests.value?.append(request)
            return (
                makeHTTPResponse(status: 401),
                try encodeJSON(["error": "Authentication required", "code": "authentication_required"])
            )
        }

        let client = Self.makeSkewedClient()
        do {
            _ = try await client.updateUserAttributes(isPaying: true, userToken: "user-clock-skew")
            Issue.record("Expected authenticationRequired error")
        } catch FeedbackClientError.authenticationRequired {
            // Only the signed-in envelope — never retried.
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
        #expect(requests.value?.count == 1)
    }

    @Test func pinnedTimestampParameterStillWinsOverTheOffset() async throws {
        let requests = CaptureBox<[URLRequest]>()
        requests.value = []
        let client = Self.makeOnTimeClient()
        // Learn an offset of +120 s from the first response's `Date` header.
        Self.installRecordingHandler(capturing: requests) { attempt in
            if attempt == 1 {
                return (
                    makeHTTPResponse(headers: ["Date": Self.serverDateHeader(secondsAfterBase: 120)]),
                    try encodeJSON(["ok": true, "updatedAt": "2026-10-07T00:00:00.000Z"])
                )
            }
            return try Self.successResponse()
        }
        _ = try await client.updateUserAttributes(userToken: "user-clock-pin")
        // The test pin overrides the corrected clock.
        _ = try await client.updateUserAttributes(
            isPaying: true,
            userToken: "user-clock-pin",
            timestamp: 1_773_600_000
        )

        let sent = try #require(requests.value)
        #expect(sent.count == 2)
        let pinData = try #require(bodyData(from: sent[1]))
        let body = try #require(parseJSONDict(pinData))
        #expect(body["timestamp"] as? Int64 == 1_773_600_000)
    }
}
