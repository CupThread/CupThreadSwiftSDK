import Foundation

/// Client-side bounds for the attachment references on `POST /api/v1/feedback`
/// (issue #613), mirroring the live `FeedbackSubmissionInput` schema the same
/// way ``IntakeTextLimits`` mirrors the intake text caps and
/// ``UploadSessionLimits`` the upload-session bounds.
///
/// The schema caps both `uploadIds` and `attachments` at `maxItems: 8` and
/// can only answer a longer array with `400 Validation failed` — after the
/// single-use Turnstile challenge was consumed for the attempt, and after
/// every referenced upload had already been streamed. The SDK therefore
/// refuses an over-cap draft locally, before the Turnstile provider is
/// consulted or any request is built, so the host can drop attachments and
/// resubmit with the remaining (still valid) upload receipts instead of
/// re-uploading everything behind generic copy that retrying cannot clear.
public enum FeedbackSubmissionLimits: Sendable {
    /// The most attachment uploads one submission may reference
    /// (`FeedbackSubmissionInput.uploadIds` `maxItems: 8`). Counted on the
    /// `uploadId`s actually forwarded: a ``FeedbackAttachment`` whose
    /// ``FeedbackAttachment/uploadId`` is `nil` (a legacy reference) never
    /// reaches the wire and does not count. The SDK's own composer stops
    /// offering the picker well below this bound; the cap matters for hosts
    /// that build their own attachment UI on the one-shot upload helpers,
    /// each of which creates its own session and so never sees the aggregate.
    public static let maxAttachmentCount = 8

    /// The upload ids `draft` would send as `uploadIds`: every non-`nil`
    /// ``FeedbackAttachment/uploadId``, in attachment order. The count gate
    /// and the wire payload both derive from this one list, so the number
    /// the gate checks is always the number the server would validate.
    static func referencedUploadIds(in draft: FeedbackDraft) -> [String] {
        draft.attachments.compactMap(\.uploadId)
    }

    /// The number of attachment uploads `draft` would reference on the wire
    /// — the figure ``maxAttachmentCount`` bounds. Published so hosts with
    /// their own attachment UI can gate the form the way
    /// ``FeedbackAttachmentStateMachine/canSubmit(draft:)`` does.
    public static func referencedUploadCount(in draft: FeedbackDraft) -> Int {
        referencedUploadIds(in: draft).count
    }
}

extension FeedbackClient {
    /// Rejects a draft referencing more uploads than
    /// ``FeedbackSubmissionLimits/maxAttachmentCount`` (issue #613) before a
    /// Turnstile token is consumed or any request is built. The server can
    /// only answer such a submission with `400 Validation failed`, and the
    /// headless programmatic path has no picker gate to stop it first —
    /// mirroring ``FeedbackAttachmentStateMachine/canSubmit(draft:)``
    /// without the UI. Counts forwarded ids, not `attachments.count`, so a
    /// legacy reference without an id is never charged against the cap.
    func validateAttachmentCount(in draft: FeedbackDraft) throws {
        guard FeedbackSubmissionLimits.referencedUploadCount(in: draft)
            <= FeedbackSubmissionLimits.maxAttachmentCount else {
            throw FeedbackClientError.tooManyAttachments()
        }
    }
}
