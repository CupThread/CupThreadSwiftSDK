import Foundation
import Testing
@testable import CupThreadFeedback

// Issue #578: the intake caps and the visible counter measured Swift
// `Character`s — extended grapheme clusters — while the server's
// `minLength`/`maxLength` bounds count Unicode code points (and UTF-16-based
// validators count at least that). Cluster count never exceeds code-point
// count, so the cluster gate was strictly looser than the server bound:
// "160-character" titles of flag sequences or ZWJ emoji passed the composer
// gate — with the counter showing 160/160 — and were answered `400
// Validation failed`. `measuredLength` now counts code points, and the
// headless intake methods enforce the caps locally (the counterpart of the
// composers' `canSubmit` form gate) before any Turnstile token or network
// activity.
@Suite("Intake Code-Point Length", .serialized)
struct IntakeCodePointLengthTests {
    static let apiHost = "intake-codepoints.example.com"

    /// One regional-indicator pair (a flag): 1 grapheme cluster, 2 code
    /// points — the smallest multi-scalar input a counter can disagree on.
    static let flag = "🇺🇸"
    /// One ZWJ family emoji: 1 grapheme cluster, 7 code points.
    static let familyEmoji = "👨‍👩‍👧‍👦"
    /// One decomposed accent: 1 grapheme cluster, 2 code points.
    static let nfdE = "e\u{301}"

    /// Thread-safe counter recording every Turnstile provider consultation.
    final class TokenCallCounter: @unchecked Sendable {
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

    static func makeCountingClient() -> (FeedbackClient, TokenCallCounter) {
        let counter = TokenCallCounter()
        let client = FeedbackClient(
            configuration: FeedbackClientConfiguration(
                baseURL: URL(string: "https://\(apiHost)")!,
                appKey: "app_codepoints1"
            ),
            session: makeMockSession(),
            turnstileTokenProvider: { _ in counter.record() }
        )
        return (client, counter)
    }

    /// A handler that records arrival and answers a valid submission receipt.
    static func recordSubmissionReceipt(into capture: CaptureBox<URLRequest>) {
        MockURLProtocol.setHandler(forHost: apiHost) { request in
            capture.value = request
            let receipt: [String: Any] = ["submissionId": "s-1"]
            return (makeHTTPResponse(status: 200), try encodeJSON(receipt))
        }
    }

    // MARK: - The counting unit

    @Test("measuredLength counts Unicode code points, not grapheme clusters")
    func measuredLengthCountsCodePoints() {
        #expect(Self.flag.count == 1)
        #expect(IntakeTextLimits.measuredLength(Self.flag) == 2)
        #expect(Self.familyEmoji.count == 1)
        #expect(IntakeTextLimits.measuredLength(Self.familyEmoji) == 7)
        #expect(Self.nfdE.count == 1)
        #expect(IntakeTextLimits.measuredLength(Self.nfdE) == 2)

        // Trimming still runs before measuring.
        #expect(IntakeTextLimits.measuredLength("  \(Self.flag)\n ") == 2)
        // ASCII is unchanged: both units agree one-to-one.
        #expect(IntakeTextLimits.measuredLength("abc") == 3)
    }

    // MARK: - Cap gates

    @Test("multi-scalar titles past a cap are rejected where cluster counting passed them")
    func overLimitFieldCatchesMultiScalarOverrun() {
        // 160 flags = 160 clusters but 320 code points: the old cluster gate
        // passed this title and the server answered `400 Validation failed`.
        let flagTitle = FeedbackDraft(
            title: String(repeating: Self.flag, count: IntakeTextLimits.maxTitleLength),
            description: "Valid description",
            platform: .ios
        )
        #expect(flagTitle.title.count == IntakeTextLimits.maxTitleLength, "The draft must look at-cap to cluster counting")
        #expect(IntakeTextLimits.overLimitField(in: flagTitle) == .title)

        // 40 family emoji = 40 clusters but 280 code points.
        let emojiTitle = FeedbackDraft(
            title: String(repeating: Self.familyEmoji, count: 40),
            description: "Valid description",
            platform: .ios
        )
        #expect(IntakeTextLimits.overLimitField(in: emojiTitle) == .title)

        // The gate stays field-specific: the over-cap title wins wire order.
        #expect(IntakeTextLimits.overLimitField(in: FeatureRequestDraft(
            title: String(repeating: Self.flag, count: IntakeTextLimits.maxTitleLength),
            description: "Valid description"
        )) == .title)

        // A multi-scalar body past the comment cap is caught too.
        let overComment = CommentDraft(body: String(repeating: Self.flag, count: IntakeTextLimits.maxCommentLength / 2 + 1))
        #expect(overComment.body.count == IntakeTextLimits.maxCommentLength / 2 + 1)
        #expect(overComment.body.unicodeScalars.count == IntakeTextLimits.maxCommentLength + 2)
        #expect(IntakeTextLimits.overLimitField(in: overComment) == .commentBody)
    }

    @Test("exactly-at-cap multi-scalar drafts pass, one code point over fails")
    func codePointBoundaryIsInclusive() {
        // 79 ASCII + 77 flags + one decomposed accent = exactly 160 code points.
        let atCap = "abcd" + String(repeating: Self.flag, count: 77) + Self.nfdE
        #expect(atCap.unicodeScalars.count == IntakeTextLimits.maxTitleLength)
        #expect(atCap.count < IntakeTextLimits.maxTitleLength, "The draft must be under the cap to cluster counting")
        #expect(IntakeTextLimits.overLimitField(in: FeedbackDraft(
            title: atCap, description: "Valid description", platform: .ios
        )) == nil)

        // One more scalar tips it over.
        #expect(IntakeTextLimits.overLimitField(in: FeedbackDraft(
            title: atCap + "x", description: "Valid description", platform: .ios
        )) == .title)
    }

    @Test("multi-scalar titles the server accepts are no longer blocked at the minimum")
    func underLimitFieldAcceptsMultiScalarAboveTheFloor() {
        // One family emoji is 1 cluster (blocked by the old gate) but 7 code
        // points — above the server's floor of 3.
        #expect(IntakeTextLimits.underLimitField(in: FeedbackDraft(
            title: Self.familyEmoji, description: "Valid description", platform: .ios
        )) == nil)

        // Two flags = 4 code points: above the floor.
        #expect(IntakeTextLimits.underLimitField(in: FeatureRequestDraft(
            title: Self.flag + Self.flag, description: "Valid description"
        )) == nil)

        // One flag = 2 code points: still genuinely below the floor.
        #expect(IntakeTextLimits.underLimitField(in: FeedbackDraft(
            title: Self.flag, description: "Valid description", platform: .ios
        )) == .title)
    }

    // MARK: - Headless cap enforcement

    @Test("submit rejects a multi-scalar over-cap draft locally with no Turnstile consultation and no network call")
    func submitRejectsMultiScalarOverCapLocally() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            let receipt: [String: Any] = ["submissionId": "s-1"]
            return (makeHTTPResponse(status: 200), try encodeJSON(receipt))
        }
        let (client, counter) = Self.makeCountingClient()
        let draft = FeedbackDraft(
            title: String(repeating: Self.flag, count: IntakeTextLimits.maxTitleLength),
            description: "Valid description",
            platform: .ios
        )

        await #expect(throws: FeedbackClientError.textTooLong) {
            _ = try await client.submit(draft)
        }
        #expect(capture.value == nil, "The cap gate must reject locally — a network request escaped")
        #expect(counter.callCount == 0, "An over-cap draft must never consume a Turnstile token")
    }

    @Test("submitFeatureRequest rejects a multi-scalar over-cap draft locally")
    func submitFeatureRequestRejectsMultiScalarOverCapLocally() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            let receipt: [String: Any] = ["featureRequestId": "fr-1", "pending": true]
            return (makeHTTPResponse(status: 200), try encodeJSON(receipt))
        }
        let (client, counter) = Self.makeCountingClient()
        let draft = FeatureRequestDraft(
            title: String(repeating: Self.familyEmoji, count: 40),
            description: "Valid description"
        )

        await #expect(throws: FeedbackClientError.textTooLong) {
            _ = try await client.submitFeatureRequest(draft, userToken: "user-1")
        }
        #expect(capture.value == nil)
        #expect(counter.callCount == 0)
    }

    @Test("postComment rejects a multi-scalar over-cap body locally")
    func postCommentRejectsMultiScalarOverCapLocally() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            let comment: [String: Any] = [
                "id": "c-1", "featureRequestId": "fr-1", "body": "ok", "createdAt": "2026-10-07T00:00:00Z"
            ]
            return (makeHTTPResponse(status: 201), try encodeJSON(["comment": comment]))
        }
        let (client, _) = Self.makeCountingClient()
        let draft = CommentDraft(body: String(repeating: Self.flag, count: IntakeTextLimits.maxCommentLength / 2 + 1))

        await #expect(throws: FeedbackClientError.textTooLong) {
            _ = try await client.postComment(featureRequestId: "fr-1", draft: draft, userToken: "user-token-1")
        }
        #expect(capture.value == nil)
    }

    @Test("a multi-scalar draft exactly at the cap still dispatches and consumes exactly one token")
    func submitAcceptsMultiScalarAtCapDraft() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.recordSubmissionReceipt(into: capture)
        let (client, counter) = Self.makeCountingClient()

        // Exactly 160 code points of multi-scalar text.
        let atCapTitle = String(repeating: Self.flag, count: 79) + Self.nfdE
        #expect(atCapTitle.unicodeScalars.count == IntakeTextLimits.maxTitleLength)
        let draft = FeedbackDraft(
            title: atCapTitle,
            description: "Valid description",
            platform: .ios
        )

        let result = try await client.submit(draft)
        #expect(result.submissionId == "s-1")
        #expect(capture.value != nil, "A draft at the code-point cap must still reach the server")
        #expect(counter.callCount == 1, "A valid draft consumes exactly one Turnstile token")
    }
}
