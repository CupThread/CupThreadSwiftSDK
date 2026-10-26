import Foundation
import Testing
@testable import CupThreadFeedback

/// Tests for the local attachment-count bound on `POST /api/v1/feedback`
/// (`submit`, issue #613): the live `FeedbackSubmissionInput` schema caps
/// `uploadIds` at `maxItems: 8` and can only answer a longer array with
/// `400 Validation failed` — after the single-use Turnstile challenge was
/// consumed and every referenced file already uploaded. The client must
/// refuse an over-cap draft locally, before the Turnstile provider is
/// consulted and before any request is sent, counting the ids it would
/// actually forward (non-`nil` `uploadId`s) rather than `attachments.count`;
/// the form gate must agree; and the residual server rejection must map to
/// the same typed error instead of generic unexpected-status copy.
///
/// The suite uses its own mock host so it cannot stomp (or be stomped by)
/// suites that share the default `test.example.com` handler.
@Suite("FeedbackSubmissionAttachmentCount", .serialized)
struct FeedbackSubmissionAttachmentCountTests {
    private static let host = "submission-attachments.example.com"
    private static var baseURL: URL { URL(string: "https://\(host)")! }
    private static var cap: Int { FeedbackSubmissionLimits.maxAttachmentCount }

    /// Thread-safe counter recording every Turnstile provider consultation.
    private final class ProviderCallCounter: @unchecked Sendable {
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

    /// Thread-safe counter for intercepted network requests.
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

    // MARK: Helpers

    /// A client whose Turnstile provider records every consultation, so a
    /// local rejection can prove the challenge was never consumed.
    private static func makeCountingClient() -> (FeedbackClient, ProviderCallCounter) {
        let provider = ProviderCallCounter()
        let client = FeedbackClient(
            configuration: FeedbackClientConfiguration(baseURL: baseURL, appKey: "app_attachcount"),
            session: makeMockSession(),
            turnstileTokenProvider: { _ in provider.record() }
        )
        return (client, provider)
    }

    private static func attachment(_ index: Int, uploadId: String?) -> FeedbackAttachment {
        FeedbackAttachment(
            kind: .image,
            uploadId: uploadId,
            key: "key-\(index)",
            url: URL(string: "https://\(host)/api/v1/uploads/upl-\(index)")!,
            filename: "f\(index).png",
            mimeType: "image/png",
            size: 10
        )
    }

    /// A draft valid in every other respect, carrying `uploadCount`
    /// attachments with distinct upload ids (`upl-0`, `upl-1`, …) followed by
    /// `legacyCount` legacy references without one.
    private static func draft(uploadCount: Int, legacyCount: Int = 0) -> FeedbackDraft {
        let uploaded = (0..<uploadCount).map { attachment($0, uploadId: "upl-\($0)") }
        let legacy = (0..<legacyCount).map { attachment(uploadCount + $0, uploadId: nil) }
        return FeedbackDraft(
            title: "Sync drops edits",
            description: "Editing while offline loses my last change.",
            platform: .ios,
            attachments: uploaded + legacy
        )
    }

    /// Installs a counting 200 handler, optionally capturing the raw
    /// submission body for wire checks.
    private static func installSubmitHandler(counter: RequestCounter, body: CaptureBox<Data>? = nil) {
        MockURLProtocol.setHandler(forHost: host) { request in
            counter.increment()
            body?.value = bodyData(from: request) ?? Data()
            return (
                makeHTTPResponse(),
                try encodeJSON(["submissionId": "s-attach", "forwardedToGithub": false])
            )
        }
    }

    /// Installs a counting 400 handler answering `Validation failed` with
    /// the given field errors and request id.
    private static func installValidationFailureHandler(
        counter: RequestCounter,
        fieldErrors: [String: [String]],
        requestId: String? = nil
    ) {
        MockURLProtocol.setHandler(forHost: host) { _ in
            counter.increment()
            let headers = requestId.map { ["X-Request-Id": $0] } ?? [:]
            return (
                makeHTTPResponse(status: 400, headers: headers),
                try encodeJSON([
                    "error": "Validation failed",
                    "details": ["fieldErrors": fieldErrors]
                ])
            )
        }
    }

    private static func assertRejectedLocally(_ draft: FeedbackDraft) async throws {
        let (client, provider) = makeCountingClient()
        let counter = RequestCounter()
        installSubmitHandler(counter: counter)

        await #expect(throws: FeedbackClientError.tooManyAttachments(message: nil, requestId: nil)) {
            _ = try await client.submit(draft, userToken: "tok")
        }
        #expect(provider.callCount == 0, "Turnstile token must not be consumed for an over-cap draft")
        #expect(counter.value == 0, "No request may be sent for an over-cap draft")
    }

    // MARK: Over-cap drafts are refused before any work

    @Test func submitRejectsOneOverTheCapLocally() async throws {
        try await Self.assertRejectedLocally(Self.draft(uploadCount: Self.cap + 1))
    }

    @Test func submitRejectsFarOverTheCapLocally() async throws {
        try await Self.assertRejectedLocally(Self.draft(uploadCount: 32))
    }

    /// Legacy references never reach the wire, so they must not shield an
    /// over-cap draft either: nine forwarded ids plus a legacy reference is
    /// still nine ids.
    @Test func submitRejectsOverCapDraftRegardlessOfLegacyReferences() async throws {
        try await Self.assertRejectedLocally(Self.draft(uploadCount: Self.cap + 1, legacyCount: 2))
    }

    @Test func localRejectionCarriesNoRequestIdAndNoResponseBody() async throws {
        let (client, _) = Self.makeCountingClient()
        Self.installSubmitHandler(counter: RequestCounter())

        do {
            _ = try await client.submit(Self.draft(uploadCount: Self.cap + 1), userToken: "tok")
            Issue.record("Expected tooManyAttachments")
        } catch let error as FeedbackClientError {
            guard case .tooManyAttachments(let message, let requestId) = error else {
                Issue.record("Expected .tooManyAttachments, got \(error)")
                return
            }
            #expect(message == nil, "nothing was sent, so there is no server text to carry")
            #expect(requestId == nil, "nothing was sent, so there is no request id to quote")
            #expect(error.requestId == nil)
            #expect(error.responseBody == nil)
        }
    }

    // MARK: Boundary counts stay accepted (no off-by-one)

    @Test func submitAcceptsExactlyTheCapAndEncodesEveryIdInOrder() async throws {
        let (client, provider) = Self.makeCountingClient()
        let counter = RequestCounter()
        let body = CaptureBox<Data>()
        Self.installSubmitHandler(counter: counter, body: body)

        let result = try await client.submit(Self.draft(uploadCount: Self.cap), userToken: "tok")

        #expect(result.submissionId == "s-attach")
        #expect(provider.callCount == 1, "A valid draft consumes exactly one Turnstile token")
        #expect(counter.value == 1)
        let rawBody = try #require(body.value)
        let payload = try #require(parseJSONDict(rawBody))
        let uploadIds = try #require(payload["uploadIds"] as? [String])
        #expect(uploadIds == (0..<Self.cap).map { "upl-\($0)" })
    }

    /// The gate counts forwarded ids, not `attachments.count`: a draft with
    /// nine attachments of which only eight carry an `uploadId` sends eight
    /// ids and is accepted.
    @Test func submitCountsForwardedIdsNotAttachments() async throws {
        let (client, provider) = Self.makeCountingClient()
        let counter = RequestCounter()
        let body = CaptureBox<Data>()
        Self.installSubmitHandler(counter: counter, body: body)

        let draft = Self.draft(uploadCount: Self.cap, legacyCount: 1)
        #expect(draft.attachments.count == Self.cap + 1)
        _ = try await client.submit(draft, userToken: "tok")

        #expect(provider.callCount == 1)
        #expect(counter.value == 1)
        let rawBody = try #require(body.value)
        let payload = try #require(parseJSONDict(rawBody))
        let uploadIds = try #require(payload["uploadIds"] as? [String])
        #expect(uploadIds.count == Self.cap)
        let forwardedALegacyPlaceholder = uploadIds.contains { $0.isEmpty }
        #expect(!forwardedALegacyPlaceholder, "a legacy reference must be dropped, never forwarded as an empty id")
    }

    /// A draft without any forwarded id keeps the long-standing
    /// field-omitted semantics: no `uploadIds` key at all, not an empty array.
    @Test func submitWithoutForwardedIdsOmitsUploadIdsEntirely() async throws {
        let (client, _) = Self.makeCountingClient()
        let counter = RequestCounter()
        let body = CaptureBox<Data>()
        Self.installSubmitHandler(counter: counter, body: body)

        _ = try await client.submit(Self.draft(uploadCount: 0, legacyCount: 3), userToken: "tok")

        #expect(counter.value == 1)
        let rawBody = try #require(body.value)
        let payload = try #require(parseJSONDict(rawBody))
        #expect(payload["uploadIds"] == nil)
    }

    // MARK: Shared bounds (FeedbackSubmissionLimits)

    @Test func maxAttachmentCountMatchesTheLiveContractCap() {
        #expect(FeedbackSubmissionLimits.maxAttachmentCount == 8)
    }

    @Test func referencedUploadCountCountsOnlyAttachmentsWithAnUploadId() {
        #expect(FeedbackSubmissionLimits.referencedUploadCount(in: Self.draft(uploadCount: 0)) == 0)
        #expect(FeedbackSubmissionLimits.referencedUploadCount(in: Self.draft(uploadCount: 0, legacyCount: 4)) == 0)
        #expect(FeedbackSubmissionLimits.referencedUploadCount(in: Self.draft(uploadCount: 3, legacyCount: 4)) == 3)
        #expect(FeedbackSubmissionLimits.referencedUploadCount(in: Self.draft(uploadCount: 9)) == 9)
    }

    @Test func referencedUploadIdsPreserveAttachmentOrder() {
        let ids = FeedbackSubmissionLimits.referencedUploadIds(in: Self.draft(uploadCount: 3, legacyCount: 1))
        #expect(ids == ["upl-0", "upl-1", "upl-2"])
    }

    // MARK: The form gate agrees with the client

    @Test func canSubmitRejectsOverCapAndAcceptsAtCap() {
        let stateMachine = FeedbackAttachmentStateMachine()
        #expect(stateMachine.canSubmit(draft: Self.draft(uploadCount: Self.cap)))
        #expect(!stateMachine.canSubmit(draft: Self.draft(uploadCount: Self.cap + 1)))
        #expect(!stateMachine.canSubmit(draft: Self.draft(uploadCount: 32)))
    }

    @Test func canSubmitIgnoresLegacyReferencesWithoutAnUploadId() {
        let stateMachine = FeedbackAttachmentStateMachine()
        #expect(stateMachine.canSubmit(draft: Self.draft(uploadCount: Self.cap, legacyCount: 3)))
        #expect(!stateMachine.canSubmit(draft: Self.draft(uploadCount: Self.cap + 1, legacyCount: 3)))
    }

    // MARK: The residual server rejection maps to the same typed error

    @Test func submitMapsUploadIdsFieldErrorToTooManyAttachmentsWithRequestId() async throws {
        let (client, _) = Self.makeCountingClient()
        let counter = RequestCounter()
        Self.installValidationFailureHandler(
            counter: counter,
            fieldErrors: ["uploadIds": ["Array must contain at most 8 element(s)"]],
            requestId: "req-400-attachments"
        )

        do {
            // Locally valid, so the request reaches the server and the mocked
            // field error isolates the envelope mapping.
            _ = try await client.submit(Self.draft(uploadCount: Self.cap), userToken: "tok")
            Issue.record("Expected tooManyAttachments")
        } catch let error as FeedbackClientError {
            guard case .tooManyAttachments(let message, let requestId) = error else {
                Issue.record("Expected .tooManyAttachments, got \(error)")
                return
            }
            #expect(message == "Validation failed")
            #expect(requestId == "req-400-attachments")
            #expect(error.requestId == "req-400-attachments")
            #expect(error.responseBody == nil, "raw server text must stay off responseBody")
            #expect(counter.value == 1, "a validation rejection is a normal error and must never be retried")
        }
    }

    @Test func submitMapsLegacyAttachmentsFieldErrorToTooManyAttachments() async throws {
        let (client, _) = Self.makeCountingClient()
        let counter = RequestCounter()
        Self.installValidationFailureHandler(counter: counter, fieldErrors: ["attachments": ["too_big"]])

        do {
            _ = try await client.submit(Self.draft(uploadCount: 1), userToken: "tok")
            Issue.record("Expected tooManyAttachments")
        } catch let error as FeedbackClientError {
            guard case .tooManyAttachments(_, let requestId) = error else {
                Issue.record("Expected .tooManyAttachments, got \(error)")
                return
            }
            #expect(requestId == nil)
            #expect(counter.value == 1)
        }
    }

    @Test func fourHundredWithoutAttachmentFieldErrorsStaysUnexpectedStatus() async throws {
        let (client, _) = Self.makeCountingClient()
        Self.installValidationFailureHandler(
            counter: RequestCounter(),
            fieldErrors: ["nickname": ["too_long"]],
            requestId: "req-400-generic"
        )

        do {
            _ = try await client.submit(Self.draft(uploadCount: 1), userToken: "tok")
            Issue.record("Expected unexpectedStatus")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, _, let requestId) = error else {
                Issue.record("Expected .unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 400)
            #expect(requestId == "req-400-generic")
        }
    }

    // MARK: User-facing copy

    @Test func tooManyAttachmentsRendersCuratedCopyWithoutServerText() throws {
        let error = FeedbackClientError.tooManyAttachments(message: "Validation failed", requestId: "req-attach-1")
        let description = try #require(error.errorDescription)
        #expect(description == CupThreadStrings.tr("cupthread.error.too_many_attachments") + " (request id: req-attach-1)")
        #expect(!description.contains("Validation failed"))
        #expect(!description.contains("cupthread.error.too_many_attachments"))
    }

    @Test func tooManyAttachmentsDescriptionOmitsRequestIdWhenRejectedLocally() throws {
        let description = try #require(FeedbackClientError.tooManyAttachments().errorDescription)
        #expect(description == CupThreadStrings.tr("cupthread.error.too_many_attachments"))
        #expect(!description.contains("request id"))
        #expect(FriendlyError.message(for: FeedbackClientError.tooManyAttachments()) == description)
    }
}
