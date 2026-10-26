import Foundation
import Testing
@testable import CupThreadFeedback

// Regression tests for #422: fetchFeatureRequests must reject a blank
// userToken before any network I/O (the header would otherwise be dropped
// and the response would read as anonymous, reporting false hasVoted), and
// normalize its pagination and filter query parameters client-side like the
// other paginated list endpoints (#425). Lives in its own suite (and host)
// so it can run in parallel with the other validation suites.
@Suite("FeatureRequestListInputValidation", .serialized)
struct FeatureRequestListInputValidationTests {
    static let apiHost = "feature-list-validation.example.com"

    static func makeValidatedClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(apiHost)")!)
    }

    static func stubListResponse(_ capture: CaptureBox<URLRequest>) {
        MockURLProtocol.setHandler(forHost: apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["requests": [], "total": 0]))
        }
    }

    // MARK: - userToken rejection

    @Test func blankUserTokenThrowsAuthenticationRequiredWithoutNetwork() async {
        let capture = CaptureBox<URLRequest>()
        Self.stubListResponse(capture)

        for blankToken in ["", "   ", " \n\t "] {
            await #expect(throws: FeedbackClientError.authenticationRequired) {
                try await Self.makeValidatedClient().fetchFeatureRequests(userToken: blankToken)
            }
        }

        #expect(capture.value == nil, "no network request may be built for a blank token")
    }

    @Test func whitespacePaddedUserTokenIsAcceptedAndTrimmed() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubListResponse(capture)

        _ = try await Self.makeValidatedClient().fetchFeatureRequests(userToken: "  tok-1  ")

        let request = try #require(capture.value)
        #expect(request.value(forHTTPHeaderField: "X-User-Token") == "tok-1")
    }

    // MARK: - limit clamping

    @Test func fetchFeatureRequestsClampsNonPositiveLimitToOne() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubListResponse(capture)

        for invalidLimit in [0, -10] {
            _ = try await Self.makeValidatedClient().fetchFeatureRequests(
                userToken: "tok-1",
                limit: invalidLimit
            )
            let request = try #require(capture.value)
            #expect(queryItems(of: request)["limit"] == "1")
        }
    }

    @Test func fetchFeatureRequestsClampsOversizedLimitToServerMaximum() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubListResponse(capture)

        _ = try await Self.makeValidatedClient().fetchFeatureRequests(userToken: "tok-1", limit: 500)

        let request = try #require(capture.value)
        #expect(queryItems(of: request)["limit"] == "200")
    }

    @Test func fetchFeatureRequestsKeepsInBoundLimitUntouched() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubListResponse(capture)

        for validLimit in [1, 50, 200] {
            _ = try await Self.makeValidatedClient().fetchFeatureRequests(
                userToken: "tok-1",
                limit: validLimit
            )
            let request = try #require(capture.value)
            #expect(queryItems(of: request)["limit"] == String(validLimit))
        }
    }

    // MARK: - offset clamping

    @Test func fetchFeatureRequestsClampsNegativeOffsetToZero() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubListResponse(capture)

        _ = try await Self.makeValidatedClient().fetchFeatureRequests(userToken: "tok-1", offset: -5)

        let request = try #require(capture.value)
        #expect(queryItems(of: request)["offset"] == "0")
    }

    @Test func fetchFeatureRequestsKeepsNonNegativeOffsetUntouched() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubListResponse(capture)

        _ = try await Self.makeValidatedClient().fetchFeatureRequests(userToken: "tok-1", offset: 40)

        let request = try #require(capture.value)
        #expect(queryItems(of: request)["offset"] == "40")
    }

    // MARK: - versionId / query / cursor sanitization

    @Test func fetchFeatureRequestsDropsWhitespaceOnlyVersionIdQueryAndCursor() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubListResponse(capture)

        _ = try await Self.makeValidatedClient().fetchFeatureRequests(
            userToken: "tok-1",
            versionId: "   ",
            query: " \n\t ",
            cursor: "\t "
        )

        let request = try #require(capture.value)
        let query = request.url?.query
        #expect(query?.contains("versionId=") == false)
        #expect(query?.contains("q=") == false)
        #expect(query?.contains("cursor=") == false)
    }

    @Test func fetchFeatureRequestsTrimsWhitespacePaddedVersionIdQueryAndCursor() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubListResponse(capture)

        _ = try await Self.makeValidatedClient().fetchFeatureRequests(
            userToken: "tok-1",
            versionId: " v-9 ",
            query: "  dark mode  ",
            cursor: "  MjAyNi0w  "
        )

        let request = try #require(capture.value)
        #expect(queryItems(of: request)["versionId"] == "v-9")
        #expect(queryItems(of: request)["q"] == "dark mode")
        #expect(queryItems(of: request)["cursor"] == "MjAyNi0w")
    }

    // MARK: - query (q) cap (#610)

    /// The live contract bounds `q` at `maxLength: 120`; an over-long term is
    /// a guaranteed rejection that would still spend a search-throttle slot,
    /// so the wire term is truncated to the cap instead (#610).
    @Test func fetchFeatureRequestsTruncatesOverLongQueryToLiveContractCap() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubListResponse(capture)

        let overLong = String(repeating: "a", count: FeatureRequestSearchLimits.maxQueryLength + 1)
        _ = try await Self.makeValidatedClient().fetchFeatureRequests(userToken: "tok-1", query: overLong)

        let request = try #require(capture.value)
        #expect(queryItems(of: request)["q"] == String(repeating: "a", count: FeatureRequestSearchLimits.maxQueryLength))
    }

    @Test func fetchFeatureRequestsKeepsQueryAtTheCapVerbatim() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubListResponse(capture)

        let atCap = String(repeating: "a", count: FeatureRequestSearchLimits.maxQueryLength)
        _ = try await Self.makeValidatedClient().fetchFeatureRequests(userToken: "tok-1", query: atCap)

        let request = try #require(capture.value)
        #expect(queryItems(of: request)["q"] == atCap)
    }

    /// The cap counts Unicode code points (#578), not grapheme clusters:
    /// 60 decomposed `e\u{0301}` pairs are exactly 120 code points and go out
    /// verbatim, while 65 pairs (130 code points) are cut at 60 whole pairs —
    /// grapheme counting would have sent the full 130-code-point term.
    @Test func fetchFeatureRequestsMeasuresQueryCapInCodePointsNotGraphemes() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubListResponse(capture)

        let atCap = String(repeating: "e\u{0301}", count: 60)
        #expect(atCap.unicodeScalars.count == 120)
        #expect(atCap.count == 60)
        _ = try await Self.makeValidatedClient().fetchFeatureRequests(userToken: "tok-1", query: atCap)
        #expect(queryItems(of: try #require(capture.value))["q"] == atCap)

        let overCap = String(repeating: "e\u{0301}", count: 65)
        #expect(overCap.unicodeScalars.count == 130)
        _ = try await Self.makeValidatedClient().fetchFeatureRequests(userToken: "tok-1", query: overCap)
        let overCapRequest = try #require(capture.value)
        let clamped = try #require(queryItems(of: overCapRequest)["q"])
        #expect(clamped == String(repeating: "e\u{0301}", count: 60))
        #expect(clamped.unicodeScalars.count == 120)
    }

    /// The cut can land on interior whitespace, and a trailing space would be
    /// sent verbatim — the clamped term is re-trimmed before it rides the wire.
    @Test func fetchFeatureRequestsReTrimsWhitespaceTheCapCutCanLeaveBehind() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubListResponse(capture)

        let padded = String(repeating: "a ", count: 70)
        #expect(padded.unicodeScalars.count == 140)
        _ = try await Self.makeValidatedClient().fetchFeatureRequests(userToken: "tok-1", query: padded)

        let request = try #require(capture.value)
        #expect(queryItems(of: request)["q"] == String(repeating: "a ", count: 59) + "a")
    }

    /// A single cluster longer than the whole cap (a long combining run) can
    /// yield an empty prefix; the query is then dropped entirely — the same
    /// blank-drop semantics a whitespace-only term has always had — instead
    /// of sending a doomed search.
    @Test func sanitizedQueryDropsQueryWhoseWholeClusterExceedsTheCap() {
        let giant = "e" + String(repeating: "\u{0301}", count: 150)
        #expect(giant.unicodeScalars.count > FeatureRequestSearchLimits.maxQueryLength)
        #expect(giant.count == 1)
        #expect(FeatureRequestSearchLimits.sanitizedQuery(giant) == nil)
    }

    @Test func sanitizedQueryPreservesShortTermsAndBlankDropSemantics() {
        #expect(FeatureRequestSearchLimits.sanitizedQuery(nil) == nil)
        #expect(FeatureRequestSearchLimits.sanitizedQuery("   ") == nil)
        #expect(FeatureRequestSearchLimits.sanitizedQuery("  dark mode  ") == "dark mode")
        let short = "dark mode"
        #expect(FeatureRequestSearchLimits.sanitizedQuery(short) == short)
    }

    @Test func sanitizedQueryTruncatesOnClusterBoundariesToTheCap() {
        let over = String(repeating: "ab", count: 70)
        let clamped = FeatureRequestSearchLimits.sanitizedQuery(over)
        #expect(clamped == String(repeating: "ab", count: 60))
        #expect(clamped?.unicodeScalars.count == FeatureRequestSearchLimits.maxQueryLength)
    }
}

// MARK: - Helpers

private func queryItems(of request: URLRequest) -> [String: String] {
    guard let url = request.url,
          let items = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems
    else { return [:] }
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
}
