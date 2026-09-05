import Foundation
import Testing
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
@testable import CupThreadFeedback

@Suite("FeedbackAttachmentManager")
struct FeedbackAttachmentManagerTests {

    // MARK: - Format detection from bytes

    @Test func detectsPNGFromBytes() {
        let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])
        let format = PhotoAttachmentHelper.detectImageFormat(from: pngHeader)
        #expect(format.mimeType == "image/png")
        #expect(format.fileExtension == "png")
    }

    @Test func detectsJPEGFromBytes() {
        let jpegHeader = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01])
        let format = PhotoAttachmentHelper.detectImageFormat(from: jpegHeader)
        #expect(format.mimeType == "image/jpeg")
        #expect(format.fileExtension == "jpg")
    }

    @Test func detectsShortJPEGFromBytes() {
        let shortJpeg = Data([0xFF, 0xD8, 0xFF])
        let format = PhotoAttachmentHelper.detectImageFormat(from: shortJpeg)
        #expect(format.mimeType == "image/jpeg")
        #expect(format.fileExtension == "jpg")
    }

    @Test func detectsGIFFromBytes() {
        let gifHeader = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00])
        let format = PhotoAttachmentHelper.detectImageFormat(from: gifHeader)
        #expect(format.mimeType == "image/gif")
        #expect(format.fileExtension == "gif")
    }

    @Test func detectsWebPFromBytes() {
        // "RIFF" .... "WEBP"
        let webpHeader = Data([0x52, 0x49, 0x46, 0x46, 0x20, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50])
        let format = PhotoAttachmentHelper.detectImageFormat(from: webpHeader)
        #expect(format.mimeType == "image/webp")
        #expect(format.fileExtension == "webp")
    }

    @Test func detectsHEICFromBytes() {
        // offset 4: 'ftyp', offset 8: 'heic'
        let heicHeader = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63])
        let format = PhotoAttachmentHelper.detectImageFormat(from: heicHeader)
        #expect(format.mimeType == "image/heic")
        #expect(format.fileExtension == "heic")
    }

    @Test func detectsHEIFBrandsFromBytes() {
        for brand in ["heix", "mif1", "msf1"] {
            var bytes: [UInt8] = [0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70]
            bytes.append(contentsOf: brand.utf8)
            let format = PhotoAttachmentHelper.detectImageFormat(from: Data(bytes))
            #expect(format.mimeType == "image/heic")
            #expect(format.fileExtension == "heic")
        }
    }

    // MARK: - UTType fallback

    #if canImport(UniformTypeIdentifiers)
    @Test func fallsBackToSupportedContentTypeWhenBytesUnrecognized() {
        let randomBytes = Data([0x01, 0x02, 0x03, 0x04])
        let format = PhotoAttachmentHelper.detectImageFormat(from: randomBytes, contentTypes: [.png])
        #expect(format.mimeType == "image/png")
        #expect(format.fileExtension == "png")

        let heicFormat = PhotoAttachmentHelper.detectImageFormat(from: randomBytes, contentTypes: [.heic])
        #expect(heicFormat.mimeType == "image/heic")
        #expect(heicFormat.fileExtension == "heic")
    }

    @Test func ignoresNonImageContentTypes() {
        let randomBytes = Data([0x01, 0x02, 0x03, 0x04])
        let format = PhotoAttachmentHelper.detectImageFormat(from: randomBytes, contentTypes: [.plainText])
        #expect(format.mimeType == "image/jpeg")
        #expect(format.fileExtension == "jpg")
    }
    #endif

    @Test func defaultsToJPEGWhenNoHintsMatch() {
        let empty = Data()
        let format = PhotoAttachmentHelper.detectImageFormat(from: empty)
        #expect(format.mimeType == "image/jpeg")
        #expect(format.fileExtension == "jpg")
    }

    // MARK: - Collision-resistant filename

    @Test func makeFilenameIncludesExtensionAndUniqueUUID() {
        let id = UUID()
        let filename = PhotoAttachmentHelper.makeFilename(fileExtension: "png", id: id)
        #expect(filename == "screenshot_\(id.uuidString.lowercased()).png")

        let auto1 = PhotoAttachmentHelper.makeFilename(fileExtension: "heic")
        let auto2 = PhotoAttachmentHelper.makeFilename(fileExtension: "heic")
        #expect(auto1 != auto2)
        #expect(auto1.hasPrefix("screenshot_"))
        #expect(auto1.hasSuffix(".heic"))
    }

    // MARK: - Attachment size validation

    @Test func validateAttachmentSizePassesUnderLimit() throws {
        try PhotoAttachmentHelper.validateAttachmentSize(1024, limit: 2048)
        try PhotoAttachmentHelper.validateAttachmentSize(2048, limit: 2048)
    }

    @Test func validateAttachmentSizeThrowsWhenExceeded() {
        #expect(throws: AttachmentValidationError.self) {
            try PhotoAttachmentHelper.validateAttachmentSize(2049, limit: 2048)
        }

        do {
            try PhotoAttachmentHelper.validateAttachmentSize(25_000_000, limit: 20_000_000)
            Issue.record("Expected oversized validation error")
        } catch let error as AttachmentValidationError {
            #expect(error == .oversized(size: 25_000_000, limit: 20_000_000))
            let description = error.errorDescription ?? ""
            #expect(description.contains("exceeds the maximum allowed size"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - State Machine: Submit-during-upload race prevention

    @Test func cannotSubmitWhileUploading() {
        var stateMachine = FeedbackAttachmentStateMachine()
        var draft = FeedbackDraft(
            title: "Valid title",
            description: "Valid description longer than 5 chars",
            platform: .ios
        )

        #expect(stateMachine.canSubmit(draft: draft))

        let uploadId = stateMachine.startUpload()
        #expect(stateMachine.isUploading)
        #expect(stateMachine.activeUploadId == uploadId)
        // Race prevented: send button disabled while in-flight upload exists
        #expect(!stateMachine.canSubmit(draft: draft))

        let sampleAttachment = FeedbackAttachment(
            kind: .image,
            key: "key-1",
            url: URL(string: "https://example.com/k1")!,
            filename: "screenshot_1.png",
            mimeType: "image/png",
            size: 100
        )
        let accepted = stateMachine.uploadSucceeded(id: uploadId, attachment: sampleAttachment, draft: &draft)
        #expect(accepted)
        #expect(!stateMachine.isUploading)
        #expect(draft.attachments.count == 1)
        #expect(stateMachine.canSubmit(draft: draft))
    }

    // MARK: - State Machine: Cancellation and superseded uploads

    @Test func supersededUploadDoesNotAppendToDraft() {
        var stateMachine = FeedbackAttachmentStateMachine()
        var draft = FeedbackDraft.autofilled(platform: .ios)

        let uploadA = stateMachine.startUpload()
        let uploadB = stateMachine.startUpload() // A is superseded by B

        let attachmentA = FeedbackAttachment(
            kind: .image,
            key: "key-a",
            url: URL(string: "https://example.com/a")!
        )
        let attachmentB = FeedbackAttachment(
            kind: .image,
            key: "key-b",
            url: URL(string: "https://example.com/b")!
        )

        // Late response from upload A is rejected
        let acceptedA = stateMachine.uploadSucceeded(id: uploadA, attachment: attachmentA, draft: &draft)
        #expect(!acceptedA)
        #expect(draft.attachments.isEmpty)

        // Response from active upload B is accepted
        let acceptedB = stateMachine.uploadSucceeded(id: uploadB, attachment: attachmentB, draft: &draft)
        #expect(acceptedB)
        #expect(draft.attachments.count == 1)
        #expect(draft.attachments.first?.key == "key-b")
    }

    @Test func cancelledUploadDoesNotAppendToDraft() {
        var stateMachine = FeedbackAttachmentStateMachine()
        var draft = FeedbackDraft.autofilled(platform: .ios)

        let uploadId = stateMachine.startUpload()
        stateMachine.cancelUpload()
        #expect(!stateMachine.isUploading)

        let attachment = FeedbackAttachment(
            kind: .image,
            key: "cancelled-key",
            url: URL(string: "https://example.com/c")!
        )
        let accepted = stateMachine.uploadSucceeded(id: uploadId, attachment: attachment, draft: &draft)
        #expect(!accepted)
        #expect(draft.attachments.isEmpty)
    }

    // MARK: - State Machine: Removal during upload

    @Test func removingExistingAttachmentDoesNotAffectInFlightUpload() {
        var stateMachine = FeedbackAttachmentStateMachine()
        var draft = FeedbackDraft.autofilled(platform: .ios)
        let existing = FeedbackAttachment(
            kind: .image,
            key: "existing-key",
            url: URL(string: "https://example.com/exist")!
        )
        draft.attachments.append(existing)

        let uploadId = stateMachine.startUpload()
        stateMachine.removeAttachment(id: existing.id, draft: &draft)
        #expect(draft.attachments.isEmpty)
        #expect(stateMachine.isUploading)

        let newAttachment = FeedbackAttachment(
            kind: .image,
            key: "new-key",
            url: URL(string: "https://example.com/new")!
        )
        let accepted = stateMachine.uploadSucceeded(id: uploadId, attachment: newAttachment, draft: &draft)
        #expect(accepted)
        #expect(draft.attachments.count == 1)
        #expect(draft.attachments.first?.key == "new-key")
    }

    // MARK: - State Machine: Upload failure and retry

    @Test func uploadFailureTransitionsToFailedStateAndAllowsRetry() {
        var stateMachine = FeedbackAttachmentStateMachine()
        var draft = FeedbackDraft.autofilled(platform: .ios)

        let uploadId = stateMachine.startUpload()
        let testError = NSError(domain: "test", code: 500, userInfo: [NSLocalizedDescriptionKey: "Server 500"])
        let recorded = stateMachine.uploadFailed(id: uploadId, error: testError)
        #expect(recorded)
        #expect(!stateMachine.isUploading)
        #expect(stateMachine.currentErrorMessage == "Server 500")
        #expect(draft.attachments.isEmpty)

        // Superseded error is ignored
        let staleError = stateMachine.uploadFailed(id: UUID(), error: testError)
        #expect(!staleError)

        // Retry with new upload clears error on success
        let retryId = stateMachine.startUpload()
        #expect(stateMachine.currentErrorMessage == nil)
        let retryAttachment = FeedbackAttachment(kind: .image, key: "retry-key", url: URL(string: "https://example.com/r")!)
        stateMachine.uploadSucceeded(id: retryId, attachment: retryAttachment, draft: &draft)
        #expect(draft.attachments.count == 1)
    }

    @Test func cancellationErrorDoesNotDisplayErrorBanner() {
        var stateMachine = FeedbackAttachmentStateMachine()

        let uploadId = stateMachine.startUpload()
        stateMachine.uploadFailed(id: uploadId, error: CancellationError())
        #expect(!stateMachine.isUploading)
        #expect(stateMachine.currentErrorMessage == nil)
    }

    // MARK: - State Machine: Reset after success

    @Test func resetRestoresCleanDraftAndIdleState() {
        var stateMachine = FeedbackAttachmentStateMachine()
        var draft = FeedbackDraft(
            title: "Old title",
            description: "Old description",
            platform: .macos
        )
        draft.attachments.append(FeedbackAttachment(kind: .image, key: "k", url: URL(string: "https://example.com/k")!))

        stateMachine.startUpload()
        stateMachine.reset(draft: &draft, defaultPlatform: .macos)

        #expect(!stateMachine.isUploading)
        #expect(stateMachine.currentErrorMessage == nil)
        #expect(draft.title.isEmpty)
        #expect(draft.description.isEmpty)
        #expect(draft.attachments.isEmpty)
        #expect(draft.platform == .macos)
    }
}
