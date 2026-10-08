import Foundation

// MARK: - Turnstile widget binding (API-15, SaaS #543)

/// The Turnstile widget binding a gated intake endpoint expects.
///
/// Every Turnstile siteverify call is bound to the `(action, cdata)` pair the
/// widget was rendered with, and a token minted under a different binding —
/// or with no binding at all — fails verification. The SDK passes one of
/// these to the configured `turnstileTokenProvider` on every consultation,
/// so the host can render (or server-mint) a token under the exact binding
/// the endpoint validates:
///
/// | Endpoint | `action` | `cdata` |
/// | --- | --- | --- |
/// | `POST /api/v1/feedback` | ``TurnstileAction/feedback`` | app key |
/// | `POST /api/v1/uploads/sessions` | ``TurnstileAction/feedback`` | app key |
/// | `POST /api/v1/feature-requests` | ``TurnstileAction/featureRequest`` | app key |
///
/// Upload sessions intentionally reuse the feedback action: the public web
/// form spends one single-use token on both the attachment session and the
/// feedback submission.
public struct TurnstileChallenge: Equatable, Sendable {
    /// The Cloudflare widget `action` the server binds verification to.
    public let action: String

    /// The Cloudflare widget `cdata` the server binds verification to —
    /// always the SDK client's app key.
    public let cdata: String

    /// Creates a challenge from an explicit binding.
    /// - Parameters:
    ///   - action: The widget `action` the endpoint validates against.
    ///   - cdata: The widget `cdata` the endpoint validates against — the
    ///     client's app key.
    public init(action: String, cdata: String) {
        self.action = action
        self.cdata = cdata
    }

    /// The binding for feedback intake (`POST /api/v1/feedback`) and
    /// attachment upload-session creation (`POST /api/v1/uploads/sessions`).
    public static func feedback(appKey: String) -> TurnstileChallenge {
        TurnstileChallenge(action: TurnstileAction.feedback, cdata: appKey)
    }

    /// The binding for feature-request submission
    /// (`POST /api/v1/feature-requests`).
    public static func featureRequest(appKey: String) -> TurnstileChallenge {
        TurnstileChallenge(action: TurnstileAction.featureRequest, cdata: appKey)
    }
}

/// Server-aligned `action` values for Turnstile-gated intake endpoints.
///
/// Render the widget (or mint a token server-side) with one of these actions
/// and the app key as `cdata` — e.g.
/// `turnstile.render({ action: TurnstileAction.feedback, cdata: appKey })`.
/// Tokens minted without a binding, or under a different action, are rejected
/// by the server's verification gate, so a
/// `feature-request`-minted token cannot be spent on feedback or upload
/// intake, and vice versa.
public enum TurnstileAction {
    /// Binding shared by `POST /api/v1/feedback` and
    /// `POST /api/v1/uploads/sessions`.
    public static let feedback = "feedback"

    /// Binding for `POST /api/v1/feature-requests`.
    public static let featureRequest = "feature-request"
}
