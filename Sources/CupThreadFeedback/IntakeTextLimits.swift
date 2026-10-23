import Foundation

/// A free-text intake field, identifying which field is over its client-side
/// cap — surfaces and tests use it to point users at the field to shorten.
public enum IntakeField: Equatable, Sendable {
    /// Feedback or feature-request title.
    case title
    /// Feedback or feature-request description.
    case description
    /// Feedback reporter or feature-requester display name.
    case name
    /// Feedback contact email.
    case email
    /// Comment body.
    case commentBody
}

/// Client-side length caps for the SDK's free-text intake fields (BUG-18).
///
/// The public API reads every intake body (feedback, feature requests,
/// comments) through a bounded reader with a 256 KB budget (SEC-36) and
/// rejects anything larger with `413` **before** validation — and that `413`
/// maps to a file-flavored error, which reads as nonsense for a text-only
/// submission. The SDK therefore caps its free-text fields locally: the
/// composers show a counter near a cap and disable submitting past it, and
/// the client refuses to send an encoded intake body above
/// ``maxSubmissionPayloadBytes`` at all. Values mirror the server's column
/// validation where one exists and stay far enough below the byte budget
/// otherwise.
public enum IntakeTextLimits: Sendable {
    /// Feedback and feature-request title floor, in trimmed characters
    /// (BUG-32): the server rejects shorter titles with `400`, so the
    /// composers disable submitting below it and the client methods refuse
    /// such drafts locally, before any network work.
    public static let minTitleLength = 3
    /// Feedback and feature-request description floor, in trimmed characters
    /// (BUG-32): the server rejects shorter descriptions with `400`, so the
    /// composers disable submitting below it and the client methods refuse
    /// such drafts locally, before any network work.
    public static let minDescriptionLength = 5
    /// Feedback and feature-request title cap, in characters
    /// (`FeedbackSubmissionInput.title` / `CreateFeatureRequestInput.title`).
    public static let maxTitleLength = 160
    /// Feedback description cap, in characters
    /// (`FeedbackSubmissionInput.description`).
    ///
    /// The two intake endpoints enforce different description bounds: feature
    /// requests cap at
    /// ``maxFeatureRequestDescriptionLength``. Sending the larger value here
    /// is answered with `400 Validation failed`, so the composers gate on the
    /// matching constant.
    public static let maxDescriptionLength = 10_000
    /// Feature-request description cap, in characters
    /// (`CreateFeatureRequestInput.description`).
    public static let maxFeatureRequestDescriptionLength = 5_000
    /// Feedback reporter and feature-requester display-name cap, in characters
    /// (`FeedbackSubmissionInput.reporterName` / `CreateFeatureRequestInput.requesterName`).
    public static let maxNameLength = 120
    /// Feedback contact-email cap, in characters.
    public static let maxEmailLength = 254
    /// Comment body cap, in characters (`CreateFeatureRequestCommentInput.body`).
    public static let maxCommentLength = 2_000
    /// Whole-payload byte budget for intake JSON bodies: half the server's
    /// 256 KB bounded-reader budget, leaving headroom for JSON structure and
    /// the SDK's reserved metadata. Measured on the encoded `httpBody`
    /// bytes, so multibyte text counts by its UTF-8 length, not its
    /// character count.
    public static let maxSubmissionPayloadBytes = 128 * 1024

    /// The whitespace-trimmed character count the caps and counters measure:
    /// mirrors the trim applied to the field on the wire, so UI counters and
    /// submission gates always agree with what is sent.
    static func measuredLength(_ text: String) -> Int {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    /// The first feedback-draft field over its cap, or `nil` when every
    /// field fits. "First" follows wire order: title, description, name,
    /// email.
    public static func overLimitField(in draft: FeedbackDraft) -> IntakeField? {
        if measuredLength(draft.title) > maxTitleLength { return .title }
        if measuredLength(draft.description) > maxDescriptionLength { return .description }
        if measuredLength(draft.reporterName) > maxNameLength { return .name }
        if measuredLength(draft.reporterEmail) > maxEmailLength { return .email }
        return nil
    }

    /// The feature-request draft field over its cap, or `nil` when every
    /// field fits. The description uses
    /// ``maxFeatureRequestDescriptionLength``, which is tighter than the
    /// feedback endpoint's bound.
    public static func overLimitField(in draft: FeatureRequestDraft) -> IntakeField? {
        if measuredLength(draft.title) > maxTitleLength { return .title }
        if measuredLength(draft.description) > maxFeatureRequestDescriptionLength { return .description }
        if measuredLength(draft.requesterName) > maxNameLength { return .name }
        return nil
    }

    /// The comment draft field over its cap, or `nil` when the body fits.
    public static func overLimitField(in draft: CommentDraft) -> IntakeField? {
        if measuredLength(draft.body) > maxCommentLength { return .commentBody }
        return nil
    }

    /// The first feedback-draft field below its minimum trimmed length, or
    /// `nil` when `title` and `description` both meet the server's floors
    /// (BUG-32). "First" follows wire order: title, description.
    public static func underLimitField(in draft: FeedbackDraft) -> IntakeField? {
        if measuredLength(draft.title) < minTitleLength { return .title }
        if measuredLength(draft.description) < minDescriptionLength { return .description }
        return nil
    }

    /// The feature-request draft field below its minimum trimmed length, or
    /// `nil` when `title` and `description` both meet the server's floors
    /// (BUG-32).
    public static func underLimitField(in draft: FeatureRequestDraft) -> IntakeField? {
        if measuredLength(draft.title) < minTitleLength { return .title }
        if measuredLength(draft.description) < minDescriptionLength { return .description }
        return nil
    }
}

// MARK: - Whole-payload budget preflight

/// Client-side whole-payload budget preflight for the intake endpoints
/// (BUG-18). The server reads every intake body through a bounded reader
/// with a 256 KB budget (SEC-36) and rejects anything larger with `413`
/// before validation — and that `413` maps to a file-flavored error, which
/// reads as nonsense for a text-only submission. Encoding and measuring the
/// body locally turns the guaranteed-failing round trip into an immediate
/// ``FeedbackClientError/textTooLong`` with actionable copy.
extension FeedbackClient {
    /// Encodes an intake JSON body and enforces
    /// ``IntakeTextLimits/maxSubmissionPayloadBytes``: an oversized body
    /// throws ``FeedbackClientError/textTooLong`` before any network
    /// activity. Byte-counts the encoded payload, so multibyte text is
    /// measured by its UTF-8 length rather than its character count.
    func encodedIntakeBody(_ body: some Encodable) throws -> Data {
        let data = try encoder.encode(body)
        guard data.count <= IntakeTextLimits.maxSubmissionPayloadBytes else {
            throw FeedbackClientError.textTooLong
        }
        return data
    }

    /// Rejects a feedback draft whose trimmed `title` or `description` is
    /// below the server's minimum intake length (BUG-32) before a Turnstile
    /// token is consumed or any request is built. The server can only answer
    /// such a submission with `400 Validation failed`, and the headless
    /// programmatic path has no form gate to stop it first — mirroring
    /// ``FeedbackAttachmentStateMachine``/``canSubmit(draft:)`` without the UI.
    func validateIntakeMinimums(in draft: FeedbackDraft) throws {
        guard IntakeTextLimits.underLimitField(in: draft) == nil else {
            throw FeedbackClientError.invalidResponse
        }
    }

    /// Rejects a feature-request draft whose trimmed `title` or
    /// `description` is below the server's minimum intake length (BUG-32),
    /// mirroring ``FeatureRequestComposeView``'s form gate without the UI.
    func validateIntakeMinimums(in draft: FeatureRequestDraft) throws {
        guard IntakeTextLimits.underLimitField(in: draft) == nil else {
            throw FeedbackClientError.invalidResponse
        }
    }
}
