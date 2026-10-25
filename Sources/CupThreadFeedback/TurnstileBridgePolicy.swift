import Foundation

// MARK: - Hosted-challenge bridge message policy (issue #566)

/// The inbound trust boundary of the `turnstileBridge` script-message
/// handler, extracted from `TurnstileWebView`'s `WKScriptMessageHandler` so
/// the decision is unit-testable without WebKit (`WKScriptMessage` and
/// `WKFrameInfo` cannot be constructed in tests).
///
/// `WKUserContentController.add(_:name:)` delivers script messages from
/// **every frame** of the page, and the handler is installed before the
/// first navigation and survives them. Without a frame check, any subframe —
/// third-party content the portal page embeds, or a compromised portal
/// origin — could post into the bridge: a synthetic `{status: "failure"}`
/// drops a working widget behind the failure overlay, and a synthetic
/// `{status: "success", token}` hands the caller an attacker-chosen value as
/// if the challenge page minted it (the API's siteverify still rejects that
/// token, but the user's genuinely solved challenge is silently discarded).
///
/// The legitimate caller is the portal page's own main-frame JavaScript —
/// the Cloudflare widget iframe reports to the page, which forwards from the
/// main frame — so a message is accepted only when it originates from the
/// **main frame of the challenge page's origin**: scheme equality with the
/// challenge URL's own scheme (so the production `https` page accepts
/// `https` origins only), case-insensitive host equality, and effective-port
/// equality with the scheme's default — the same comparison semantics as
/// `SameOriginRedirectLimiter.isSameOrigin`. Pinning to the challenge URL's
/// scheme instead of hardcoding `https` keeps the self-hosted/local
/// `turnstileChallengeURL` overrides working while leaving the production
/// guarantee identical. Everything else is dropped silently, exactly like an
/// unknown message name today.
enum TurnstileBridgePolicy {
    /// - Parameters:
    ///   - isMainFrame: `message.frameInfo.isMainFrame`.
    ///   - originProtocol: `message.frameInfo.securityOrigin.protocol`
    ///     (compared case-insensitively).
    ///   - originHost: `message.frameInfo.securityOrigin.host` (compared
    ///     case-insensitively).
    ///   - originPort: `message.frameInfo.securityOrigin.port`; WebKit
    ///     reports `0` for an implicit default port, which normalizes to the
    ///     scheme's default here.
    ///   - challengeURL: the URL the sheet loaded, defining the allowed
    ///     origin.
    /// - Returns: `true` when the message may reach the sheet's handler.
    static func acceptsBridgeMessage(
        isMainFrame: Bool,
        originProtocol: String,
        originHost: String,
        originPort: Int,
        challengeURL: URL
    ) -> Bool {
        guard isMainFrame,
              let scheme = challengeURL.scheme?.lowercased(),
              originProtocol.lowercased() == scheme,
              let challengeHost = challengeURL.host?.lowercased(),
              !challengeHost.isEmpty,
              !originHost.isEmpty,
              originHost.lowercased() == challengeHost
        else { return false }
        return effectivePort(explicit: originPort, scheme: scheme)
            == effectivePort(explicit: challengeURL.port, scheme: scheme)
    }

    /// Effective port with the scheme's default, so `https://host` and
    /// `https://host:443` are one origin. WebKit answers `0` for an implicit
    /// default port on `WKSecurityOrigin.port` where `URL.port` answers
    /// `nil` — both normalize to the scheme's default here.
    private static func effectivePort(explicit: Int?, scheme: String) -> Int {
        guard let explicit, explicit != 0 else {
            return scheme == "https" ? 443 : 80
        }
        return explicit
    }
}
