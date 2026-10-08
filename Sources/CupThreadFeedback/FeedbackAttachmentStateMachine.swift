import Foundation

// Extracted from FeedbackAttachmentManager.swift so the helper and the
// value-type state machine each stay under the library file-size budget.

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
    /// Whether an explicit limit was provided by the caller upon initialization.
    public let hasExplicitLimit: Bool

    /// Whether the state machine accepts dynamic console configuration limits (`true` when initialized without an explicit limit).
    public var usesConfigLimit: Bool {
        !hasExplicitLimit
    }

    /// Creates a state machine with an optional explicit attachment size limit.
    ///
    /// When `maxAttachmentBytes` is `nil`, the state machine falls back to
    /// ``PhotoAttachmentHelper/defaultMaxAttachmentBytes`` and allows future
    /// console configuration updates via ``applyConfigLimit(_:)``.
    /// When an explicit non-nil limit is provided, ``applyConfigLimit(_:)``
    /// will not override it.
    ///
    /// - Parameter maxAttachmentBytes: Upper byte limit for uploaded files, or `nil` to use defaults and console config.
    public init(maxAttachmentBytes: Int? = nil) {
        self.state = .idle
        if let maxAttachmentBytes {
            self.maxAttachmentBytes = maxAttachmentBytes
            self.hasExplicitLimit = true
        } else {
            self.maxAttachmentBytes = PhotoAttachmentHelper.defaultMaxAttachmentBytes
            self.hasExplicitLimit = false
        }
    }

    /// Applies the console configuration upload byte limit if no explicit limit was provided by the caller.
    ///
    /// If the state machine was initialized with an explicit non-nil `maxAttachmentBytes`, this method is a no-op,
    /// preserving the caller's explicit limit.
    ///
    /// - Parameter limit: The byte limit from `PublicAppConfig.maxAttachmentBytes`.
    /// - Returns: `true` if the limit was applied, or `false` if ignored due to an explicit caller limit.
    @discardableResult
    public mutating func applyConfigLimit(_ limit: Int) -> Bool {
        guard !hasExplicitLimit else { return false }
        maxAttachmentBytes = limit
        return true
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
    ///   - error: The underlying failure. Task and network cancellation (``Error/isSdkCancellation``) resets state to `.idle` without an error banner.
    /// - Returns: `true` if the failure matched the active upload, or `false` if ignored.
    @discardableResult
    public mutating func uploadFailed(id: UUID, error: Error) -> Bool {
        guard case .uploading(let currentId) = state, currentId == id else {
            return false
        }
        if error.isSdkCancellation {
            state = .idle
        } else {
            state = .failed(id: id, message: FriendlyError.message(for: error))
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
    /// Submission is rejected while an attachment is uploading, when
    /// title/description length requirements are unmet, or when any free-text
    /// field is over its ``IntakeTextLimits`` cap (BUG-18).
    /// - Parameter draft: The draft to inspect.
    /// - Returns: `true` if the form is ready to submit.
    public func canSubmit(draft: FeedbackDraft) -> Bool {
        guard !isUploading else { return false }
        let titleTrimmed = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let descriptionTrimmed = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard titleTrimmed.count >= 3, descriptionTrimmed.count >= 5 else { return false }
        return IntakeTextLimits.overLimitField(in: draft) == nil
    }

    /// Removes an existing attachment from the draft by identifier.
    /// - Parameters:
    ///   - id: Attachment identifier to remove.
    ///   - draft: The draft to modify.
    public func removeAttachment(id: String, draft: inout FeedbackDraft) {
        draft.attachments.removeAll { $0.id == id }
    }
}
