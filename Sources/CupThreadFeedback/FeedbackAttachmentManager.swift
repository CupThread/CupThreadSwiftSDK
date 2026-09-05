import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Errors encountered during local validation of an attachment before upload.
public enum AttachmentValidationError: LocalizedError, Equatable, Sendable {
    /// The attachment exceeds the app's maximum allowed upload size.
    case oversized(size: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .oversized(let size, let limit):
            let formattedLimit = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)
            let formattedSize = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            return "Attachment (\(formattedSize)) exceeds the maximum allowed size of \(formattedLimit)."
        }
    }
}

/// Helper methods for deriving representation formats, filenames, and validation rules for attachments.
public enum PhotoAttachmentHelper {
    /// Default maximum attachment upload size in bytes (20 MB), mirroring `PublicAppConfig.maxAttachmentBytes`.
    public static let defaultMaxAttachmentBytes = 20_000_000

    #if canImport(UniformTypeIdentifiers)
    /// Detects the most accurate MIME type and file extension from raw data and optional source content types.
    ///
    /// Evaluates magic bytes first to match actual file contents, then falls back to `contentTypes`
    /// conforming to `UTType.image`, and defaults to JPEG if unspecified.
    ///
    /// - Parameters:
    ///   - data: The raw image bytes.
    ///   - contentTypes: Supported content types provided by the photo picker item.
    /// - Returns: A tuple containing the MIME type and file extension.
    public static func detectImageFormat(
        from data: Data,
        contentTypes: [UTType] = []
    ) -> (mimeType: String, fileExtension: String) {
        if let sniffed = sniffImageFormat(from: data) {
            return sniffed
        }

        for type in contentTypes where type.conforms(to: .image) {
            let mime = type.preferredMIMEType ?? "image/jpeg"
            let ext = type.preferredFilenameExtension ?? "jpg"
            return (mime, ext)
        }

        return ("image/jpeg", "jpg")
    }
    #else
    /// Detects the most accurate MIME type and file extension from raw data.
    ///
    /// - Parameter data: The raw image bytes.
    /// - Returns: A tuple containing the MIME type and file extension.
    public static func detectImageFormat(
        from data: Data
    ) -> (mimeType: String, fileExtension: String) {
        if let sniffed = sniffImageFormat(from: data) {
            return sniffed
        }
        return ("image/jpeg", "jpg")
    }
    #endif

    /// Sniffs common image format magic headers from raw bytes.
    ///
    /// Supports PNG, JPEG, GIF, WebP, and HEIC/HEIF containers.
    /// - Parameter data: The raw bytes to inspect.
    /// - Returns: A tuple with the detected MIME type and extension, or `nil` if unrecognized.
    public static func sniffImageFormat(from data: Data) -> (mimeType: String, fileExtension: String)? {
        if data.count >= 8 {
            let bytes = [UInt8](data.prefix(12))

            // PNG: 89 50 4E 47 0D 0A 1A 0A
            if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
                return ("image/png", "png")
            }

            // JPEG: FF D8 FF
            if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
                return ("image/jpeg", "jpg")
            }

            // GIF: 47 49 46 38 ("GIF8")
            if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) {
                return ("image/gif", "gif")
            }

            // WebP: RIFF .... WEBP
            if bytes.count >= 12,
               bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
               bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
                return ("image/webp", "webp")
            }

            // HEIC / HEIF / ISO Base Media: offset 4: 'ftyp'
            if bytes.count >= 12,
               bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
                let brand = String(bytes: bytes[8..<12], encoding: .ascii)?.lowercased() ?? ""
                let supportedBrands = ["heic", "heix", "heim", "heis", "hevc", "hevx", "mif1", "msf1"]
                if supportedBrands.contains(brand) {
                    return ("image/heic", "heic")
                }
            }
        } else if data.count >= 3 && [UInt8](data.prefix(3)) == [0xFF, 0xD8, 0xFF] {
            return ("image/jpeg", "jpg")
        }

        return nil
    }

    /// Generates a collision-resistant filename incorporating a unique UUID.
    ///
    /// - Parameters:
    ///   - fileExtension: The target file extension without a leading dot.
    ///   - id: The unique identifier for the attachment.
    /// - Returns: A filename string formatted as `"screenshot_<uuid>.<ext>"`.
    public static func makeFilename(fileExtension: String, id: UUID = UUID()) -> String {
        "screenshot_\(id.uuidString.lowercased()).\(fileExtension)"
    }

    /// Validates that raw data size does not exceed the allowed byte budget.
    ///
    /// - Parameters:
    ///   - size: Size in bytes of the file.
    ///   - limit: Maximum allowed size in bytes.
    /// - Throws: ``AttachmentValidationError/oversized(size:limit:)`` if `size > limit`.
    public static func validateAttachmentSize(_ size: Int, limit: Int) throws {
        guard size <= limit else {
            throw AttachmentValidationError.oversized(size: size, limit: limit)
        }
    }
}

/// State machine governing attachment selection, upload lifecycle, cancellation, and draft coordination.
public struct FeedbackAttachmentStateMachine: Sendable {
    /// Active state of the attachment upload flow.
    public enum State: Equatable, Sendable {
        /// No active upload is running.
        case idle
        /// An upload with the given tracking ID is actively in progress.
        case uploading(id: UUID)
        /// The upload with the given tracking ID failed with an error message.
        case failed(id: UUID, message: String)
    }

    /// The current state of the attachment pipeline.
    public private(set) var state: State
    /// Maximum allowed attachment bytes for client-side preflight validation.
    public var maxAttachmentBytes: Int

    /// Creates a state machine with a given attachment size limit.
    /// - Parameter maxAttachmentBytes: Upper byte limit for uploaded files.
    public init(maxAttachmentBytes: Int = PhotoAttachmentHelper.defaultMaxAttachmentBytes) {
        self.state = .idle
        self.maxAttachmentBytes = maxAttachmentBytes
    }

    /// Whether an upload is currently in flight.
    public var isUploading: Bool {
        if case .uploading = state { return true }
        return false
    }

    /// Identifier of the currently active upload, if any.
    public var activeUploadId: UUID? {
        if case .uploading(let id) = state { return id }
        return nil
    }

    /// Error message from the most recent failure, if in the failed state.
    public var currentErrorMessage: String? {
        if case .failed(_, let message) = state { return message }
        return nil
    }

    /// Begins a new upload cycle and transitions to `.uploading`.
    /// - Parameter id: Unique token identifying the upload task.
    /// - Returns: The token assigned to this upload session.
    @discardableResult
    public mutating func startUpload(id: UUID = UUID()) -> UUID {
        state = .uploading(id: id)
        return id
    }

    /// Records a successful upload, appending the result to the draft if the task token matches.
    ///
    /// If the upload was superseded or cancelled, the result is discarded.
    /// - Parameters:
    ///   - id: The task token that completed.
    ///   - attachment: The uploaded attachment receipt.
    ///   - draft: The draft to append to.
    /// - Returns: `true` if the attachment was accepted and appended, or `false` if ignored.
    @discardableResult
    public mutating func uploadSucceeded(
        id: UUID,
        attachment: FeedbackAttachment,
        draft: inout FeedbackDraft
    ) -> Bool {
        guard case .uploading(let currentId) = state, currentId == id else {
            return false
        }
        draft.attachments.append(attachment)
        state = .idle
        return true
    }

    /// Records an upload failure or cancellation.
    ///
    /// - Parameters:
    ///   - id: The task token that failed.
    ///   - error: The underlying failure. `CancellationError` resets state to `.idle` without an error banner.
    /// - Returns: `true` if the failure matched the active upload, or `false` if ignored.
    @discardableResult
    public mutating func uploadFailed(id: UUID, error: Error) -> Bool {
        guard case .uploading(let currentId) = state, currentId == id else {
            return false
        }
        if error is CancellationError {
            state = .idle
        } else {
            state = .failed(id: id, message: error.localizedDescription)
        }
        return true
    }

    /// Cancels any in-flight upload tracking and returns to `.idle`.
    public mutating func cancelUpload() {
        state = .idle
    }

    /// Clears any existing error banner if currently in the `.failed` state.
    public mutating func clearError() {
        if case .failed = state {
            state = .idle
        }
    }

    /// Resets the attachment state machine and replaces the draft with a fresh autofilled template.
    /// - Parameters:
    ///   - draft: The draft instance to reset.
    ///   - defaultPlatform: Platform to autofill into the new draft.
    public mutating func reset(draft: inout FeedbackDraft, defaultPlatform: FeedbackPlatform) {
        state = .idle
        draft = FeedbackDraft.autofilled(platform: defaultPlatform)
    }

    /// Validates whether the feedback form can currently be submitted.
    ///
    /// Submission is rejected while an attachment is uploading, or when title/description length requirements are unmet.
    /// - Parameter draft: The draft to inspect.
    /// - Returns: `true` if the form is ready to submit.
    public func canSubmit(draft: FeedbackDraft) -> Bool {
        guard !isUploading else { return false }
        let titleTrimmed = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let descriptionTrimmed = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return titleTrimmed.count >= 3 && descriptionTrimmed.count >= 5
    }

    /// Removes an existing attachment from the draft by identifier.
    /// - Parameters:
    ///   - id: Attachment identifier to remove.
    ///   - draft: The draft to modify.
    public func removeAttachment(id: String, draft: inout FeedbackDraft) {
        draft.attachments.removeAll { $0.id == id }
    }
}
