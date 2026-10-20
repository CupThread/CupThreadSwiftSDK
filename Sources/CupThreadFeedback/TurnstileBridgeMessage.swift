import Foundation

// MARK: - Hosted challenge bridge (SaaS #1052)

/// One message the hosted challenge page posts to the native host through
/// the `turnstileBridge` script-message handler.
///
/// The page on the portal origin renders the widget and posts
/// `{status: "success", token}`, `{status: "error", code}`, or
/// `{status: "expired"}` — the cross-SDK contract shared with the Android,
/// Flutter, and React Native clients. Tokens are single-use and valid for
/// 300 seconds, so every gated call opens the page (and consumes a token)
/// exactly once.
enum TurnstileBridgeMessage: Equatable, Sendable {
    /// The widget minted a token; consume it exactly once.
    case token(String)
    /// The widget rejected the challenge client-side. `code` is the raw
    /// widget code (e.g. `110200` — domain not allowlisted) or the page's
    /// synthetic `challenge_unavailable` / `challenge_timeout`.
    case failure(code: String?)
    /// A previously minted token expired before the host consumed it.
    case expired

    /// Parses a `WKScriptMessage`-bridged JavaScript object.
    static func parse(_ body: Any) -> TurnstileBridgeMessage? {
        guard let payload = body as? [String: Any],
              let status = payload["status"] as? String else {
            return nil
        }
        switch status {
        case "success":
            guard let token = (payload["token"] as? String)?.nilIfEmpty else { return nil }
            return .token(token)
        case "error":
            return .failure(code: code(from: payload["code"]))
        case "expired":
            return .expired
        default:
            return nil
        }
    }

    /// Widget codes arrive as strings from the page's error callback and as
    /// numbers when the bridge serializes them; both expose the same code.
    private static func code(from raw: Any?) -> String? {
        if let raw = raw as? String {
            return raw.nilIfEmpty
        }
        if let raw = raw as? NSNumber {
            return raw.stringValue
        }
        return nil
    }
}
