import Foundation
import Testing
@testable import CupThreadFeedback

/// Pins the version-string clamp on `POST /api/v1/feedback` (issue #618):
/// the live contract bounds `FeedbackSubmissionInput.appVersion` and
/// `.buildNumber` at `maxLength: 64`, and both fields are host-set
/// environment values the end user cannot shorten — so an over-long value
/// is truncated to the bound on the wire instead of spending a Turnstile
/// challenge on a guaranteed `400 Validation failed`. The bound counts
/// Unicode code points (#578) and cuts on whole grapheme-cluster
/// boundaries, the same conventions as the #610 search-term clamp. The
/// live-schema parity tripwire lives in
/// ``FeedbackSubmissionSchemaParityTests``.
@Suite("FeedbackVersionStringClamp", .serialized)
struct FeedbackVersionStringClampTests {
    static let host = "version-clamp.example.com"

    /// Thread-safe counter for Turnstile provider consultations.
    final class ProviderCounter: @unchecked Sendable {
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

    func makeClient(counter: ProviderCounter = ProviderCounter()) -> FeedbackClient {
        FeedbackClient(
            configuration: FeedbackClientConfiguration(
                baseURL: URL(string: "https://\(Self.host)")!,
                appKey: "app_versionclamp"
            ),
            session: makeMockSession(),
            turnstileTokenProvider: { _ in
                counter.increment()
                return "turnstile-token"
            }
        )
    }

    func stubSubmissionCapturingBody(_ capture: CaptureBox<Data>) {
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            capture.value = bodyData(from: request)
            let receipt: [String: Any] = ["submissionId": "s-1"]
            return (makeHTTPResponse(status: 200), try encodeJSON(receipt))
        }
    }

    func wireValue(_ field: String, from body: Data?) throws -> String? {
        let data = try #require(body, "the intercepted request must carry a body")
        let dict = try #require(parseJSONDict(data))
        return dict[field] as? String
    }

    // MARK: Over-long values are clamped, and the submission succeeds

    /// A host folding a channel/commit suffix into its version string gets a
    /// clamped wire value and a successful submission — one Turnstile token
    /// consumed, not a doomed round trip.
    @Test func overLongAppVersionIsClampedAndSubmissionSucceedsWithOneTurnstileToken() async throws {
        let counter = ProviderCounter()
        let capture = CaptureBox<Data>()
        stubSubmissionCapturingBody(capture)

        let overLong = String(repeating: "a", count: IntakeTextLimits.maxVersionLength + 20)
        var draft = FeedbackDraft(title: "Clamp me", description: "Long version string", platform: .ios)
        draft.appVersion = overLong

        let result = try await makeClient(counter: counter).submit(draft)
        #expect(result.submissionId == "s-1")
        #expect(counter.value == 1, "a successful first attempt must consume exactly one Turnstile token")

        let wire = try #require(try wireValue("appVersion", from: capture.value))
        #expect(wire == String(repeating: "a", count: IntakeTextLimits.maxVersionLength))
    }

    @Test func overLongBuildNumberIsClampedTheSameWay() async throws {
        let capture = CaptureBox<Data>()
        stubSubmissionCapturingBody(capture)

        let draft = FeedbackDraft(
            title: "Clamp me",
            description: "Long build number",
            platform: .ios,
            buildNumber: String(repeating: "9", count: IntakeTextLimits.maxVersionLength + 1)
        )

        _ = try await makeClient().submit(draft)
        let wire = try #require(try wireValue("buildNumber", from: capture.value))
        #expect(wire == String(repeating: "9", count: IntakeTextLimits.maxVersionLength))
    }

    // MARK: The cap boundary itself

    @Test func versionAtTheCapGoesOutVerbatim() async throws {
        let capture = CaptureBox<Data>()
        stubSubmissionCapturingBody(capture)

        let atCap = String(repeating: "v", count: IntakeTextLimits.maxVersionLength)
        let draft = FeedbackDraft(title: "At cap", description: "Exact-fit version", platform: .ios, appVersion: atCap)

        _ = try await makeClient().submit(draft)
        #expect(try wireValue("appVersion", from: capture.value) == atCap)
    }

    /// The cap counts Unicode code points (#578), not grapheme clusters:
    /// 32 decomposed `e\u{0301}` pairs are exactly 64 code points and go out
    /// verbatim, while 40 pairs (80 code points, 40 graphemes) are cut at 32
    /// whole pairs — never mid-cluster.
    @Test func versionClampCountsCodePointsNotGraphemes() async throws {
        let capture = CaptureBox<Data>()
        stubSubmissionCapturingBody(capture)

        let atCap = String(repeating: "e\u{0301}", count: 32)
        #expect(atCap.unicodeScalars.count == IntakeTextLimits.maxVersionLength)
        #expect(atCap.count == 32)
        var draft = FeedbackDraft(title: "Accents", description: "Decomposed version", platform: .ios)
        draft.appVersion = atCap
        _ = try await makeClient().submit(draft)
        #expect(try wireValue("appVersion", from: capture.value) == atCap)

        let overCap = String(repeating: "e\u{0301}", count: 40)
        #expect(overCap.unicodeScalars.count == 80)
        draft.appVersion = overCap
        _ = try await makeClient().submit(draft)
        let clamped = try #require(try wireValue("appVersion", from: capture.value))
        #expect(clamped == String(repeating: "e\u{0301}", count: 32))
        #expect(clamped.unicodeScalars.count == IntakeTextLimits.maxVersionLength)
    }

    /// A cut landing on interior whitespace re-trims before riding the wire:
    /// a trailing space would be sent verbatim otherwise.
    @Test func clampedVersionIsReTrimmedWhenTheCutLandsOnWhitespace() throws {
        let padded = "2.1.0 " + String(repeating: "x ", count: 40)
        let clamped = try #require(IntakeTextLimits.wireVersionValue(padded))
        #expect(clamped.unicodeScalars.count <= IntakeTextLimits.maxVersionLength)
        #expect(!clamped.hasSuffix(" "), "the clamp must not leave a trailing space on the wire value")
        #expect(clamped.hasSuffix("x"))
    }

    // MARK: Blank-drop semantics are unchanged

    @Test func blankVersionValuesAreStillOmittedFromThePayload() async throws {
        let capture = CaptureBox<Data>()
        stubSubmissionCapturingBody(capture)

        let draft = FeedbackDraft(
            title: "Anonymous env",
            description: "Blank version fields",
            platform: .ios,
            appVersion: "   ",
            buildNumber: "\n\t "
        )

        _ = try await makeClient().submit(draft)
        let body = try #require(capture.value)
        let dict = try #require(parseJSONDict(body))
        #expect(dict["appVersion"] == nil, "a whitespace-only appVersion must stay field-omitted")
        #expect(dict["buildNumber"] == nil)
    }

    // MARK: wireVersionValue unit behavior

    @Test func wireVersionValueDropsFieldValueWhoseWholeClusterExceedsTheCap() {
        let giant = "2" + String(repeating: "\u{0301}", count: IntakeTextLimits.maxVersionLength)
        #expect(giant.unicodeScalars.count > IntakeTextLimits.maxVersionLength)
        #expect(giant.count == 1, "the fixture must be a single grapheme cluster")
        #expect(IntakeTextLimits.wireVersionValue(giant) == nil)
    }

    @Test func wireVersionValuePreservesShortAndBlankInputs() {
        #expect(IntakeTextLimits.wireVersionValue("") == nil)
        #expect(IntakeTextLimits.wireVersionValue("   ") == nil)
        #expect(IntakeTextLimits.wireVersionValue("  2.1.0  ") == "2.1.0")
        #expect(IntakeTextLimits.wireVersionValue("2.1.0-beta.3+142") == "2.1.0-beta.3+142")
    }

    // MARK: The published bound is pinned

    @Test func versionCapMatchesThePublishedServerBound() {
        #expect(IntakeTextLimits.maxVersionLength == 64)
    }
}
