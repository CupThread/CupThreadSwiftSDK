import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Upload lifecycle policy (#47)

/// Pins the composer's upload-cancellation policy: only explicit,
/// user-intent-bearing transitions stop an in-flight upload. No "view
/// disappeared" transition exists — a transient disappearance
/// (`NavigationStack` push, `TabView` tab switch) must leave the active
/// upload untouched, so it can complete and land in the draft.
@Suite("FeedbackUploadLifecycle")
struct FeedbackUploadLifecycleTests {

    private func makeAttachment(key: String) -> FeedbackAttachment {
        FeedbackAttachment(kind: .image, key: key, url: URL(string: "https://example.com/\(key)")!)
    }

    // MARK: Policy: uploads survive everything except explicit transitions

    @Test func uploadingSurvivesNonCancellingOperations() {
        var machine = FeedbackAttachmentStateMachine(maxAttachmentBytes: nil)
        var draft = FeedbackDraft.autofilled(platform: .ios)
        let uploadId = machine.startUpload()

        // Everything the composer does while a photo uploads, none of which
        // expresses intent to cancel. No lifecycle signal exists at all.
        machine.applyConfigLimit(30_000_000)
        machine.removeAttachment(id: "nonexistent", draft: &draft)
        _ = machine.canSubmit(draft: draft)
        _ = machine.uploadSucceeded(id: UUID(), attachment: makeAttachment(key: "stale"), draft: &draft)
        _ = machine.uploadFailed(id: UUID(), error: NSError(domain: "test", code: 1))
        machine.clearError()

        #expect(machine.isUploading)
        #expect(machine.activeUploadId == uploadId)
        #expect(draft.attachments.isEmpty)
    }

    @Test func explicitCancelButtonReturnsToIdleAndDiscardsLateResult() {
        var machine = FeedbackAttachmentStateMachine()
        let uploadId = machine.startUpload()

        machine.cancelUpload() // the uploading row's X button

        #expect(!machine.isUploading)
        var draft = FeedbackDraft.autofilled(platform: .ios)
        let accepted = machine.uploadSucceeded(id: uploadId, attachment: makeAttachment(key: "late"), draft: &draft)
        #expect(!accepted)
        #expect(draft.attachments.isEmpty)
    }

    @Test func submitSuccessResetReturnsToIdle() {
        var machine = FeedbackAttachmentStateMachine()
        var draft = FeedbackDraft(title: "Valid title", description: "Valid description", platform: .ios)

        machine.startUpload()
        machine.reset(draft: &draft, defaultPlatform: .ios) // submit success path

        #expect(!machine.isUploading)
        #expect(draft.attachments.isEmpty)
    }

    @Test func cancelIsIdempotentAndDoesNotAffectSubsequentUploadId() {
        var machine = FeedbackAttachmentStateMachine()
        _ = machine.startUpload()

        machine.cancelUpload()
        machine.cancelUpload() // repeated cancel is a no-op
        #expect(machine.state == .idle)

        // A subsequent upload gets a fresh id and completes normally
        let nextId = machine.startUpload()
        #expect(machine.activeUploadId == nextId)
        var draft = FeedbackDraft.autofilled(platform: .ios)
        let accepted = machine.uploadSucceeded(id: nextId, attachment: makeAttachment(key: "next"), draft: &draft)
        #expect(accepted)
        #expect(draft.attachments.count == 1)
    }

    // MARK: FeedbackUploadHandle

    @Test func cancelActiveUploadWithoutComposerIsNoOp() {
        let handle = FeedbackUploadHandle()
        handle.cancelActiveUpload()
        handle.cancelActiveUpload() // idempotent
    }

    @Test func cancelActiveUploadInvokesRegisteredHandler() {
        let handle = FeedbackUploadHandle()
        let calls = CaptureBox<Int>()
        calls.value = 0
        handle.setCancelHandler { calls.value = (calls.value ?? 0) + 1 }

        handle.cancelActiveUpload()
        handle.cancelActiveUpload()

        #expect(calls.value == 2)
    }

    @Test func newUploadRegistrationReplacesPreviousTarget() {
        let handle = FeedbackUploadHandle()
        let firstCalls = CaptureBox<Int>()
        firstCalls.value = 0
        let secondCalls = CaptureBox<Int>()
        secondCalls.value = 0

        let firstTask = Task {}
        handle.setCancelHandler {
            firstCalls.value = (firstCalls.value ?? 0) + 1
            firstTask.cancel()
        }

        // A superseding upload re-points the handle before any cancel arrives
        let secondTask = Task {}
        handle.setCancelHandler {
            secondCalls.value = (secondCalls.value ?? 0) + 1
            secondTask.cancel()
        }

        handle.cancelActiveUpload()

        #expect(firstCalls.value == 0)
        #expect(secondCalls.value == 1)
        #expect(!firstTask.isCancelled)
        #expect(secondTask.isCancelled)
    }

    @Test func handleCancellationResetsMachineAndNextUploadGetsFreshId() async {
        var machine = FeedbackAttachmentStateMachine()
        var draft = FeedbackDraft.autofilled(platform: .ios)
        let firstUploadId = machine.startUpload()
        let firstTask = Task { try? await Task.sleep(for: .seconds(5)) }

        // The composer registers exactly this: cancelling the current task.
        let handle = FeedbackUploadHandle()
        handle.setCancelHandler { firstTask.cancel() }

        handle.cancelActiveUpload()
        #expect(firstTask.isCancelled)

        // The composer's unwind path resets the machine for the cancelled id
        // (uploadPhotoItem treats any cancellation as a silent reset).
        let recorded = machine.uploadFailed(id: firstUploadId, error: CancellationError())
        #expect(recorded)
        #expect(!machine.isUploading)
        #expect(machine.currentErrorMessage == nil)

        // The next upload is unaffected and completes
        let secondUploadId = machine.startUpload()
        #expect(secondUploadId != firstUploadId)
        let accepted = machine.uploadSucceeded(
            id: secondUploadId,
            attachment: makeAttachment(key: "second"),
            draft: &draft
        )
        #expect(accepted)
        #expect(draft.attachments.count == 1)
    }
}

// MARK: - Upload completion contract (delayed mock, distinct host)

/// Contract tests over the real upload path with a delayed mock transport:
/// with no cancellation event anywhere, an upload must complete and its
/// result must be accepted by the state machine.
///
/// Both tests share one mock host, so they are serialized to keep the second
/// test's handler from replacing the first mid-flight.
@Suite("FeedbackUploadCompletionContract", .serialized)
struct FeedbackUploadCompletionContractTests {
    private let host = "upload-lifecycle.example.com"

    private let sessionJSON: [String: Any] = [
        "session": [
            "sessionId": "sess-1",
            "sessionToken": "stok-abc",
            "expiresAt": "2026-09-30T12:00:00Z",
            "maxFileSizeBytes": 20_000_000,
            "maxFiles": 8
        ],
        "files": [[
            "clientFileId": "file-1",
            "uploadId": "upl-1",
            "uploadUrl": "https://upload-lifecycle.example.com/api/v1/uploads/upl-1",
            "maxSizeBytes": 20_000_000
        ]]
    ]

    private let uploadedJSON: [String: Any] = [
        "uploadId": "upl-1",
        "clientFileId": "file-1",
        "filename": "f.png",
        "contentType": "image/png",
        "sizeBytes": 5,
        "stored": true,
        "downloadUrl": "https://example.com/f.png"
    ]

    @Test func uploadCompletesWhenNoOneCancelsIt() async throws {
        MockURLProtocol.setHandler(forHost: host) { [sessionJSON, uploadedJSON] request in
            Thread.sleep(forTimeInterval: 0.25) // simulated slow network
            if request.url?.path == "/api/v1/uploads/sessions" {
                return (makeHTTPResponse(status: 201), try encodeJSON(sessionJSON))
            }
            return (makeHTTPResponse(status: 200), try encodeJSON(uploadedJSON))
        }

        let client = makeClient(baseURL: URL(string: "https://\(host)")!)
        var machine = FeedbackAttachmentStateMachine()
        var draft = FeedbackDraft.autofilled(platform: .ios)
        let uploadId = machine.startUpload()

        // Only events: startUpload → await completion. No cancel anywhere.
        let attachment = try await client.uploadAttachment(
            data: Data("hello".utf8), filename: "f.png", mimeType: "image/png", userToken: nil
        )

        let accepted = machine.uploadSucceeded(id: uploadId, attachment: attachment, draft: &draft)
        #expect(accepted)
        #expect(!machine.isUploading)
        #expect(draft.attachments.count == 1)
        #expect(draft.attachments.first?.uploadId == "upl-1")
    }

    @Test func midFlightCancellationSurfacesNoErrorAndResetsMachine() async throws {
        // The response is irrelevant: the transfer is cancelled long before
        // the delayed reply could ever arrive.
        MockURLProtocol.setHandler(forHost: host) { _ in
            Thread.sleep(forTimeInterval: 1.0) // far longer than the cancel delay
            return (makeHTTPResponse(status: 200), Data())
        }

        let client = makeClient(baseURL: URL(string: "https://\(host)")!)
        var machine = FeedbackAttachmentStateMachine()
        var draft = FeedbackDraft.autofilled(platform: .ios)
        let uploadId = machine.startUpload()

        let task = Task {
            try await client.uploadAttachment(
                data: Data("hello".utf8), filename: "f.png", mimeType: "image/png", userToken: nil
            )
        }

        // Real-dismissal cancellation, exactly as FeedbackUploadHandle drives it
        try? await Task.sleep(for: .seconds(0.1))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected the cancelled upload to throw")
        } catch {
            // Any thrown error is fine (URLError.cancelled / CancellationError);
            // the point is that the transfer stopped instead of completing.
        }

        // Composer unwind: silent reset — no error banner, nothing appended
        let recorded = machine.uploadFailed(id: uploadId, error: CancellationError())
        #expect(recorded)
        #expect(machine.state == .idle)
        #expect(machine.currentErrorMessage == nil)
        #expect(draft.attachments.isEmpty)
    }
}
