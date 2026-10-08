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
    /// Feedback and feature-request title cap, in characters.
    public static let maxTitleLength = 200
    /// Feedback and feature-request description cap, in characters.
    public static let maxDescriptionLength = 20_000
    /// Feedback reporter and feature-requester display-name cap, in characters.
    public static let maxNameLength = 100
    /// Feedback contact-email cap, in characters.
    public static let maxEmailLength = 254
    /// Comment body cap, in characters.
    public static let maxCommentLength = 5_000
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
    /// field fits.
    public static func overLimitField(in draft: FeatureRequestDraft) -> IntakeField? {
        if measuredLength(draft.title) > maxTitleLength { return .title }
        if measuredLength(draft.description) > maxDescriptionLength { return .description }
        if measuredLength(draft.requesterName) > maxNameLength { return .name }
        return nil
    }

    /// The comment draft field over its cap, or `nil` when the body fits.
    public static func overLimitField(in draft: CommentDraft) -> IntakeField? {
        if measuredLength(draft.body) > maxCommentLength { return .commentBody }
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
}
