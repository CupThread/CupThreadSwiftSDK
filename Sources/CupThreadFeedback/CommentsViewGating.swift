import SwiftUI

// MARK: - Resolved-access gating (BUG-24)

/// The comment surface's interactive affordances gate on the *resolved*
/// authenticated access (``FeedbackClient/resolveAuthenticatedAccess()``),
/// re-read on every load — provider presence alone cannot tell a signed-out
/// user of an unconditionally-installed provider apart, and a composer gated
/// on presence could only end in a server-rejected submission.
extension CommentsView {
    /// What the compose footer renders for the current session (BUG-24).
    enum ComposeAreaPresentation: Equatable, Sendable {
        /// The comment thread itself is unavailable (server 404): no footer.
        case unavailable
        /// Signed-in access resolved: the interactive composer.
        case composer
        /// No signed-in access: the deliberate signed-out notice.
        case signInRequired
    }

    static func composeAreaPresentation(
        isCommentsUnavailable: Bool,
        isAuthenticated: Bool
    ) -> ComposeAreaPresentation {
        if isCommentsUnavailable {
            return .unavailable
        }
        return isAuthenticated ? .composer : .signInRequired
    }

    /// Whether the per-comment reply button renders: replies are signed-in-only
    /// on the server, so the affordance follows the resolved access verdict,
    /// not provider presence (BUG-24).
    static func showsReplyButton(canReply: Bool, isAuthenticated: Bool) -> Bool {
        canReply && isAuthenticated
    }
}
