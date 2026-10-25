import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Client-side intake text budget (BUG-18 / SEC-36)

/// Pins the client-side free-text intake budget introduced for BUG-18:
///
/// 1. The three intake submission paths (feedback, feature request, comment)
///    reject an encoded payload above ``IntakeTextLimits/maxSubmissionPayloadBytes``
///    **locally** with ``FeedbackClientError/textTooLong`` — the mock session
///    records zero network activity, so a doomed round trip (and its
///    file-flavored `413` banner) can no longer happen.
/// 2. The new error's copy talks about text length, never files; the
///    upload-path `payloadTooLarge` copy is untouched.
/// 3. Per-field caps: ``IntakeTextLimits/overLimitField(in:)`` names the
///    offending field for all three draft types, the feedback state
///    machine's `canSubmit` gates on it, and the counter visibility
///    threshold behaves at the 80% boundary.
/// 4. Lengths are measured in Unicode code points (#578) — the unit the
///    server's `minLength`/`maxLength` validation counts — so multi-scalar
///    input (flag sequences, ZWJ emoji, decomposed accents) is gated on its
///    true wire length, and the headless intake methods reject over-cap
///    drafts locally before any Turnstile token or network activity.
@Suite("IntakeTextBudget", .serialized)
struct IntakeTextBudgetTests {
    static let host = "intake-budget.example.com"
    static let baseURL = URL(string: "https://\(host)")!

    /// Multibyte payload that blows past the 128 KB byte budget while its
    /// *character* count stays modest — pins byte-based measurement. It also
    /// exceeds every per-field cap (#578), so the cap gate rejects such a
    /// draft first (same `textTooLong` error, still with no network); the
    /// byte budget itself is pinned directly by
    /// `encodedIntakeBodyStillEnforcesTheByteBudget` below.
    static let multibyteOverBudgetBody = String(repeating: "あ", count: 50_000) // 150 KB UTF-8
    /// Multibyte payloads within every per-field cap (#578) yet large on the
    /// wire — pin that neither gate over-triggers on legitimately long
    /// multibyte text.
    static let feedbackUnderCapDescription = String(repeating: "あ", count: 9_000) // 27 KB UTF-8, ≤ 10 000 cp
    static let featureRequestUnderCapDescription = String(repeating: "あ", count: 4_900) // 14.7 KB, ≤ 5 000 cp
    static let commentUnderCapBody = String(repeating: "あ", count: 1_950) // 5.9 KB, ≤ 2 000 cp

    // MARK: Helpers

    /// Request-recording handler: every intercepted network request appends
    /// here, so zero recorded requests proves a purely local rejection.
    func makeRecordingHandler() -> RequestRecorder {
        let recorder = RequestRecorder()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            recorder.record(request)
            let receipt: [String: Any] = ["submissionId": "s-1"]
            return (makeHTTPResponse(status: 200), try encodeJSON(receipt))
        }
        return recorder
    }

    /// Thread-safe request counter for the mock session.
    final class RequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func record(_ request: URLRequest) {
            lock.lock()
            defer { lock.unlock() }
            count += 1 // arrival alone is the signal; bodies are irrelevant here
        }

        var requestCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    func makeClient(
        turnstileTokenProvider: (@Sendable (TurnstileChallenge) async -> String?)? = nil
    ) -> FeedbackClient {
        FeedbackClient(
            configuration: FeedbackClientConfiguration(
                baseURL: Self.baseURL,
                appKey: "app_intakebudget"
            ),
            session: makeMockSession(),
            turnstileTokenProvider: turnstileTokenProvider
        )
    }

    // MARK: Feedback submit (requirement 1)

    /// The oversized fixture exceeds the per-field caps (#578) as well as the
    /// byte budget, so the cap gate rejects it first — both gates throw
    /// `textTooLong` locally with no network activity, which is the pinned
    /// contract here.
    @Test func oversizedFeedbackPayloadRejectsWithoutNetwork() async {
        let recorder = makeRecordingHandler()
        let client = makeClient()
        let draft = FeedbackDraft(
            title: "Crash log attached below",
            description: Self.multibyteOverBudgetBody,
            platform: .ios
        )

        do {
            _ = try await client.submit(draft)
            Issue.record("Expected textTooLong, but submit succeeded")
        } catch FeedbackClientError.textTooLong {
            // expected
        } catch {
            Issue.record("Expected .textTooLong, got \(error)")
        }
        #expect(recorder.requestCount == 0, "The payload budget must reject locally — a network request escaped")
    }

    @Test func oversizedFeedbackPayloadRejectsWithoutNetworkEvenWithTurnstileProvider() async {
        let recorder = makeRecordingHandler()
        let client = makeClient(turnstileTokenProvider: { _ in "tok-1234567890" })
        let draft = FeedbackDraft(
            title: "Crash log attached below",
            description: Self.multibyteOverBudgetBody,
            platform: .ios
        )

        do {
            _ = try await client.submit(draft)
            Issue.record("Expected textTooLong, but submit succeeded")
        } catch FeedbackClientError.textTooLong {
            // expected
        } catch {
            Issue.record("Expected .textTooLong, got \(error)")
        }
        #expect(recorder.requestCount == 0)
    }

    @Test func largeUnderBudgetFeedbackPayloadStillSends() async throws {
        let recorder = makeRecordingHandler()
        let client = makeClient()
        let draft = FeedbackDraft(
            title: "Long repro",
            description: Self.feedbackUnderCapDescription,
            platform: .ios
        )

        let result = try await client.submit(draft)
        #expect(result.submissionId == "s-1")
        #expect(recorder.requestCount == 1, "A payload under the budget must still reach the server")
    }

    /// The per-field caps (#578) reject intake drafts before the byte budget
    /// is consulted, so the budget itself is pinned directly on
    /// `encodedIntakeBody` with a payload no cap-respecting draft can build.
    @Test func encodedIntakeBodyStillEnforcesTheByteBudget() throws {
        let client = makeClient()
        struct HugePayload: Encodable { let body: String }

        do {
            _ = try client.encodedIntakeBody(HugePayload(body: Self.multibyteOverBudgetBody))
            Issue.record("Expected textTooLong, but the oversized payload encoded")
        } catch FeedbackClientError.textTooLong {
            // expected
        } catch {
            Issue.record("Expected .textTooLong, got \(error)")
        }

        let withinBudget = try client.encodedIntakeBody(HugePayload(body: Self.feedbackUnderCapDescription))
        #expect(withinBudget.count <= IntakeTextLimits.maxSubmissionPayloadBytes)
    }

    // MARK: Feature-request submit (requirement 1)

    @Test func oversizedFeatureRequestPayloadRejectsWithoutNetwork() async {
        let recorder = makeRecordingHandler()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            recorder.record(request)
            let receipt: [String: Any] = ["featureRequestId": "fr-1", "pending": true]
            return (makeHTTPResponse(status: 200), try encodeJSON(receipt))
        }
        let client = makeClient()
        let draft = FeatureRequestDraft(
            title: "Idea",
            description: Self.multibyteOverBudgetBody,
            requesterName: "Ada"
        )

        do {
            _ = try await client.submitFeatureRequest(draft, userToken: "user-token-1")
            Issue.record("Expected textTooLong, but submitFeatureRequest succeeded")
        } catch FeedbackClientError.textTooLong {
            // expected
        } catch {
            Issue.record("Expected .textTooLong, got \(error)")
        }
        #expect(recorder.requestCount == 0)
    }

    @Test func largeUnderBudgetFeatureRequestPayloadStillSends() async throws {
        let recorder = makeRecordingHandler()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            recorder.record(request)
            let receipt: [String: Any] = ["featureRequestId": "fr-1", "pending": true]
            return (makeHTTPResponse(status: 200), try encodeJSON(receipt))
        }
        let client = makeClient()
        let draft = FeatureRequestDraft(
            title: "Idea",
            description: Self.featureRequestUnderCapDescription,
            requesterName: "Ada"
        )

        let result = try await client.submitFeatureRequest(draft, userToken: "user-token-1")
        #expect(result.featureRequestId == "fr-1")
        #expect(recorder.requestCount == 1)
    }

    // MARK: Comment submit (requirement 1)

    @Test func oversizedCommentPayloadRejectsWithoutNetwork() async {
        let recorder = makeRecordingHandler()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            recorder.record(request)
            let comment: [String: Any] = [
                "id": "c-1", "featureRequestId": "fr-1", "body": "ok", "createdAt": "2026-10-07T00:00:00Z"
            ]
            return (makeHTTPResponse(status: 201), try encodeJSON(["comment": comment]))
        }
        let client = makeClient()
        let draft = CommentDraft(body: Self.multibyteOverBudgetBody)

        do {
            _ = try await client.postComment(featureRequestId: "fr-1", draft: draft, userToken: "user-token-1")
            Issue.record("Expected textTooLong, but postComment succeeded")
        } catch FeedbackClientError.textTooLong {
            // expected
        } catch {
            Issue.record("Expected .textTooLong, got \(error)")
        }
        #expect(recorder.requestCount == 0)
    }

    @Test func largeUnderBudgetCommentPayloadStillSends() async throws {
        let recorder = makeRecordingHandler()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            recorder.record(request)
            let comment: [String: Any] = [
                "id": "c-1", "featureRequestId": "fr-1", "body": "ok", "createdAt": "2026-10-07T00:00:00Z"
            ]
            return (makeHTTPResponse(status: 201), try encodeJSON(["comment": comment]))
        }
        let client = makeClient()
        let draft = CommentDraft(body: Self.commentUnderCapBody)

        let comment = try await client.postComment(featureRequestId: "fr-1", draft: draft, userToken: "user-token-1")
        #expect(comment.id == "c-1")
        #expect(recorder.requestCount == 1)
    }

    // MARK: Error copy (requirement 2)

    @Test func textTooLongCopyNamesTextLengthNeverFiles() throws {
        let error = FeedbackClientError.textTooLong
        let desc = try #require(error.errorDescription)

        // Locale-independent identity: the case renders its own key.
        #expect(desc == CupThreadStrings.tr("cupthread.error.text_too_long"))

        // The shipped English copy names text length, never files (the
        // upload path keeps the file-flavored payloadTooLarge copy).
        let enValue = try #require(Self.enStrings()["cupthread.error.text_too_long"])
        #expect(enValue.contains("too long"))
        #expect(!enValue.lowercased().contains("file"))
    }

    @Test func payloadTooLargeCopyStillTalksAboutFiles() throws {
        // The upload path's copy is unchanged by BUG-18: it still names files.
        let desc = try #require(FeedbackClientError.payloadTooLarge(message: nil).errorDescription)
        #expect(desc.contains("file is too large"))
    }

    @Test func textTooLongCarriesNoRequestIdOrResponseBody() {
        let error = FeedbackClientError.textTooLong
        #expect(error.requestId == nil, "The rejection happens before any request exists")
        #expect(error.responseBody == nil)
    }

    private static func enStrings() throws -> [String: String] {
        let stringsURL = try #require(
            Bundle.module.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en"),
            "Missing en Localizable.strings"
        )
        let data = try Data(contentsOf: stringsURL)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try #require(plist as? [String: String])
    }

    // MARK: Per-field caps (requirement 3)

    @Test func feedbackDraftOverLimitFieldMatrix() {
        // At-cap and under-cap drafts expose no field.
        let atCap = FeedbackDraft(
            title: String(repeating: "t", count: IntakeTextLimits.maxTitleLength),
            description: String(repeating: "d", count: IntakeTextLimits.maxDescriptionLength),
            reporterName: String(repeating: "n", count: IntakeTextLimits.maxNameLength),
            reporterEmail: String(repeating: "e", count: IntakeTextLimits.maxEmailLength - 10) + "@x.example",
            platform: .ios
        )
        #expect(IntakeTextLimits.overLimitField(in: atCap) == nil)

        // One character past each cap names that field, in wire order.
        var overTitle = atCap
        overTitle.title += "!"
        #expect(IntakeTextLimits.overLimitField(in: overTitle) == .title)

        var overDescription = atCap
        overDescription.description += "!"
        #expect(IntakeTextLimits.overLimitField(in: overDescription) == .description)

        var overName = atCap
        overName.reporterName += "!"
        #expect(IntakeTextLimits.overLimitField(in: overName) == .name)

        var overEmail = atCap
        overEmail.reporterEmail = String(repeating: "e", count: IntakeTextLimits.maxEmailLength + 1)
        #expect(IntakeTextLimits.overLimitField(in: overEmail) == .email)
    }

    @Test func capMeasuresTrimmedLengthNotRawLength() {
        // Trailing whitespace is trimmed on the wire, so it never counts
        // toward a cap: the gate and the counter must agree with the payload.
        var draft = FeedbackDraft(
            title: String(repeating: "t", count: IntakeTextLimits.maxTitleLength),
            description: "d",
            platform: .ios
        )
        draft.title += String(repeating: " ", count: 500)
        #expect(IntakeTextLimits.overLimitField(in: draft) == nil)
        #expect(IntakeTextLimits.measuredLength(draft.title) == IntakeTextLimits.maxTitleLength)
    }

    @Test func featureRequestDraftOverLimitFieldMatrix() {
        let atCap = FeatureRequestDraft(
            title: String(repeating: "t", count: IntakeTextLimits.maxTitleLength),
            description: String(repeating: "d", count: IntakeTextLimits.maxFeatureRequestDescriptionLength),
            requesterName: String(repeating: "n", count: IntakeTextLimits.maxNameLength)
        )
        #expect(IntakeTextLimits.overLimitField(in: atCap) == nil)

        var overTitle = atCap
        overTitle.title += "!"
        #expect(IntakeTextLimits.overLimitField(in: overTitle) == .title)

        var overDescription = atCap
        overDescription.description += "!"
        #expect(IntakeTextLimits.overLimitField(in: overDescription) == .description)

        var overName = atCap
        overName.requesterName += "!"
        #expect(IntakeTextLimits.overLimitField(in: overName) == .name)
    }

    /// The two intake endpoints cap `description` differently, so a
    /// feature-request draft that fits the feedback bound must still be
    /// rejected here — and the shared constant must not be used for both.
    @Test func featureRequestDescriptionUsesItsOwnTighterCap() {
        #expect(IntakeTextLimits.maxFeatureRequestDescriptionLength < IntakeTextLimits.maxDescriptionLength)

        let betweenCaps = FeatureRequestDraft(
            title: "Idea",
            description: String(repeating: "d", count: IntakeTextLimits.maxFeatureRequestDescriptionLength + 1)
        )
        #expect(IntakeTextLimits.overLimitField(in: betweenCaps) == .description)

        // The same length is within the feedback endpoint's bound.
        let feedbackAtThatLength = FeedbackDraft(
            title: "Feedback",
            description: String(repeating: "d", count: IntakeTextLimits.maxFeatureRequestDescriptionLength + 1),
            platform: .ios
        )
        #expect(IntakeTextLimits.overLimitField(in: feedbackAtThatLength) == nil)
    }

    /// Pins each cap to the value the live OpenAPI document serves, so a
    /// future server-side change is a deliberate, visible edit here.
    @Test func fieldCapsMatchThePublishedServerBounds() {
        #expect(IntakeTextLimits.maxTitleLength == 160)
        #expect(IntakeTextLimits.maxDescriptionLength == 10_000)
        #expect(IntakeTextLimits.maxFeatureRequestDescriptionLength == 5_000)
        #expect(IntakeTextLimits.maxNameLength == 120)
        #expect(IntakeTextLimits.maxCommentLength == 2_000)
        #expect(IntakeTextLimits.minTitleLength == 3)
        #expect(IntakeTextLimits.minDescriptionLength == 5)
    }

    @Test func commentDraftOverLimitFieldMatrix() {
        let atCap = CommentDraft(body: String(repeating: "b", count: IntakeTextLimits.maxCommentLength))
        #expect(IntakeTextLimits.overLimitField(in: atCap) == nil)

        var overBody = atCap
        overBody.body += "!"
        #expect(IntakeTextLimits.overLimitField(in: overBody) == .commentBody)
    }

    @Test func feedbackStateMachineCanSubmitGatesOnFieldCaps() {
        let stateMachine = FeedbackAttachmentStateMachine()
        let valid = FeedbackDraft(title: "Valid title", description: "Valid description", platform: .ios)
        #expect(stateMachine.canSubmit(draft: valid))

        // One character past any cap disables submission.
        var overTitle = valid
        overTitle.title = String(repeating: "t", count: IntakeTextLimits.maxTitleLength + 1)
        #expect(!stateMachine.canSubmit(draft: overTitle))

        var overDescription = valid
        overDescription.description = String(repeating: "d", count: IntakeTextLimits.maxDescriptionLength + 1)
        #expect(!stateMachine.canSubmit(draft: overDescription))

        var overName = valid
        overName.reporterName = String(repeating: "n", count: IntakeTextLimits.maxNameLength + 1)
        #expect(!stateMachine.canSubmit(draft: overName))

        var overEmail = valid
        overEmail.reporterEmail = String(repeating: "e", count: IntakeTextLimits.maxEmailLength + 1)
        #expect(!stateMachine.canSubmit(draft: overEmail))

        // Exactly at every cap still submits.
        var atCap = valid
        atCap.title = String(repeating: "t", count: IntakeTextLimits.maxTitleLength)
        atCap.description = String(repeating: "d", count: IntakeTextLimits.maxDescriptionLength)
        atCap.reporterName = String(repeating: "n", count: IntakeTextLimits.maxNameLength)
        atCap.reporterEmail = String(repeating: "e", count: IntakeTextLimits.maxEmailLength)
        #expect(stateMachine.canSubmit(draft: atCap))

        // Minimum-length rules are unaffected by the cap work.
        #expect(!stateMachine.canSubmit(draft: FeedbackDraft(title: "ab", description: "Valid description", platform: .ios)))
    }

    // MARK: Counter visibility (requirement 3)

    @Test func counterAppearsAtEightyPercentAndStaysVisiblePastTheCap() {
        let limit = 200
        #expect(!CharacterCounterRow.isVisible(length: 0, limit: limit))
        #expect(!CharacterCounterRow.isVisible(length: 159, limit: limit), "159/200 is below the 80% threshold")
        #expect(CharacterCounterRow.isVisible(length: 160, limit: limit), "160/200 is exactly 80%")
        #expect(CharacterCounterRow.isVisible(length: 200, limit: limit))
        #expect(CharacterCounterRow.isVisible(length: 201, limit: limit), "Over-cap drafts need the counter most")
        #expect(!CharacterCounterRow.isVisible(length: 0, limit: 0), "Degenerate limits stay hidden")
    }

    }
