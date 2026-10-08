import Foundation
import Testing
@testable import CupThreadFeedback

// Issue #257: a 409 `already_finalized` rejection on POST /api/v1/feedback means
// an attachment uploadId was already consumed by a concurrent or retried submission.
// The SDK must surface the typed error with curated copy, and the composer must clear
// consumed attachments so retries do not re-send the stale upload IDs.
@Suite("AlreadyFinalized Error Mapping", .serialized)
struct AlreadyFinalizedErrorMappingTests {
    static let apiHost = "already-finalized.example.com"

    static func makeAPIClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(apiHost)")!)
    }

    // MARK: - Wire mapping

    @Test func feedbackSubmitMapsAlreadyFinalizedEnvelopeToTypedError() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 409, headers: ["X-Request-Id": "req-409-fin"]),
                try encodeJSON([
                    "error": "Upload object upl-123 has already been finalized into another submission",
                    "code": "already_finalized"
                ])
            )
        }

        do {
            _ = try await Self.makeAPIClient().submit(
                FeedbackDraft(title: "Test", description: "Body", platform: .ios),
                userToken: "token-123"
            )
            Issue.record("Expected alreadyFinalized")
        } catch let error as FeedbackClientError {
            guard case .alreadyFinalized(let message, let requestId) = error else {
                Issue.record("Expected .alreadyFinalized, got \(error)")
                return
            }
            #expect(message == "Upload object upl-123 has already been finalized into another submission")
            #expect(requestId == "req-409-fin")
            #expect(error.requestId == "req-409-fin")
            #expect(error.responseBody == nil, "raw server text must stay off responseBody")
        }
    }

    @Test func feedbackSubmitMapsAlreadyFinalizedEnvelopeWithoutRequestId() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 409),
                try encodeJSON([
                    "error": "Upload object upl-123 has already been finalized into another submission",
                    "code": "already_finalized"
                ])
            )
        }

        do {
            _ = try await Self.makeAPIClient().submit(
                FeedbackDraft(title: "Test", description: "Body", platform: .ios),
                userToken: "token-123"
            )
            Issue.record("Expected alreadyFinalized")
        } catch let error as FeedbackClientError {
            guard case .alreadyFinalized(let message, let requestId) = error else {
                Issue.record("Expected .alreadyFinalized, got \(error)")
                return
            }
            #expect(message == "Upload object upl-123 has already been finalized into another submission")
            #expect(requestId == nil)
            #expect(error.requestId == nil)
        }
    }

    @Test func other409sStayUnexpectedStatusForFeedbackSubmit() async throws {
        // Only the documented `already_finalized` envelope maps to the typed
        // error; any other 409 keeps the diagnostic unexpectedStatus.
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 409, headers: ["X-Request-Id": "req-409-other"]),
                try encodeJSON(["error": "Conflict", "code": "conflict_unrecognized"])
            )
        }

        do {
            _ = try await Self.makeAPIClient().submit(
                FeedbackDraft(title: "Test", description: "Body", platform: .ios),
                userToken: "token-123"
            )
            Issue.record("Expected unexpectedStatus")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, _, let requestId) = error else {
                Issue.record("Expected unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 409)
            #expect(requestId == "req-409-other")
        }
    }

    @Test func missing409CodeStaysUnexpectedStatus() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 409), try encodeJSON(["error": "Generic conflict"]))
        }

        do {
            _ = try await Self.makeAPIClient().submit(
                FeedbackDraft(title: "Test", description: "Body", platform: .ios),
                userToken: "token-123"
            )
            Issue.record("Expected unexpectedStatus")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, _, _) = error else {
                Issue.record("Expected unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 409)
        }
    }

    // MARK: - User-facing copy

    @Test func alreadyFinalizedRendersCuratedCopyWithoutServerText() {
        let error = FeedbackClientError.alreadyFinalized(
            message: "<html>Upload object upl-123 has already been finalized into another submission</html>",
            requestId: "req-fin-1"
        )
        let expected = "This feedback or attachment has already been submitted. (request id: req-fin-1)"
        #expect(error.errorDescription == expected)
        #expect(!error.errorDescription!.contains("<html>"))
        #expect(!error.errorDescription!.contains("Upload object"))
        #expect(FriendlyError.message(for: error) == expected)
    }

    @Test func alreadyFinalizedDescriptionOmitsRequestIdWhenAbsent() throws {
        let error = FeedbackClientError.alreadyFinalized(message: "details", requestId: nil)
        let desc = try #require(error.errorDescription)
        #expect(desc == "This feedback or attachment has already been submitted.")
        #expect(!desc.contains("request id"))
        #expect(!desc.contains("cupthread.error.already_finalized"))
    }

    // MARK: - Attachment-recovery predicate

    @Test func clearsConsumedAttachmentsForAlreadyFinalizedOnly() {
        #expect(
            FeedbackComposerView.clearsConsumedAttachments(
                for: FeedbackClientError.alreadyFinalized(message: "details", requestId: nil)
            )
        )
        #expect(
            !FeedbackComposerView.clearsConsumedAttachments(
                for: FeedbackClientError.unexpectedStatus(code: 409, message: "conflict", requestId: nil)
            )
        )
        #expect(
            !FeedbackComposerView.clearsConsumedAttachments(
                for: FeedbackClientError.rateLimited(message: "rate", requestId: nil)
            )
        )
        #expect(
            !FeedbackComposerView.clearsConsumedAttachments(
                for: FeedbackClientError.submissionQuotaExceeded(message: "quota", requestId: nil)
            )
        )
        #expect(!FeedbackComposerView.clearsConsumedAttachments(for: FeedbackClientError.authenticationRequired))
        #expect(!FeedbackComposerView.clearsConsumedAttachments(for: URLError(.timedOut)))
    }

    @Test func clearingConsumedAttachmentsRemovesOnlyUploadIdAttachments() {
        var draft = FeedbackDraft(title: "Title", description: "Desc", platform: .ios)
        let consumedAttachment = FeedbackAttachment(
            kind: .image,
            uploadId: "upl-consumed",
            key: "key-consumed",
            url: URL(string: "https://example.com/c.png")!
        )
        let nonUploadedAttachment = FeedbackAttachment(
            kind: .image,
            uploadId: nil,
            key: "key-local",
            url: URL(string: "https://example.com/l.png")!
        )
        draft.attachments = [consumedAttachment, nonUploadedAttachment]

        let machine = FeedbackAttachmentStateMachine()
        if FeedbackComposerView.clearsConsumedAttachments(for: FeedbackClientError.alreadyFinalized()) {
            for attachment in draft.attachments where attachment.uploadId != nil {
                machine.removeAttachment(id: attachment.id, draft: &draft)
            }
        }

        #expect(draft.attachments.count == 1)
        #expect(draft.attachments.first?.id == "key-local")
    }
}
