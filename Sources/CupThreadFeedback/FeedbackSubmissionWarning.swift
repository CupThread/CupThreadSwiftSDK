import Foundation

/// Maps server-provided feedback submission warnings to curated, localized copy.
///
/// Under the SDK's security contract (#30, #198), server-provided text from
/// `POST /api/v1/feedback` (`FeedbackSubmissionResult.warning`) is treated as
/// diagnostic-only (for host logging or `onSubmit` inspections). It must never be
/// rendered verbatim into end-user UI surfaces, as raw server strings can embed
/// HTML, internal proxy pages, or uncurated text.
///
/// This mapper converts machine-readable warning codes (e.g. `attachment_signing_unconfigured`)
/// and non-empty server warnings to deterministic, localized messages.
public enum FeedbackSubmissionWarning: Sendable {
    /// Machine-readable warning code indicating that attachment signing/storage is unconfigured on the server.
    public static let attachmentSigningUnconfigured = "attachment_signing_unconfigured"

    /// Maps a warning code and optional raw diagnostic message to a localized, user-facing display string.
    ///
    /// - Parameters:
    ///   - code: Machine-readable warning code (e.g. `attachment_signing_unconfigured`).
    ///   - warning: Raw diagnostic warning from the server. Used only to determine if an
    ///     uncurated warning was present when `code` is omitted or unrecognized.
    /// - Returns: A localized user-facing message, or `nil` if no warning is present.
    public static func message(code: String?, warning: String? = nil) -> String? {
        if let code = code?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty {
            switch code {
            case attachmentSigningUnconfigured:
                return CupThreadStrings.tr("cupthread.feedback.warning_attachment_signing_unconfigured")
            default:
                return CupThreadStrings.tr("cupthread.feedback.warning_generic")
            }
        }

        if let warning = warning?.trimmingCharacters(in: .whitespacesAndNewlines), !warning.isEmpty {
            return CupThreadStrings.tr("cupthread.feedback.warning_generic")
        }

        return nil
    }

    /// Convenience method to resolve user-facing warning copy from a `FeedbackSubmissionResult`.
    ///
    /// - Parameter result: The submission result returned by `FeedbackClient.submit`.
    /// - Returns: A localized user-facing message, or `nil` if no warning was returned.
    public static func message(for result: FeedbackSubmissionResult) -> String? {
        message(code: result.warningCode, warning: result.warning)
    }
}
