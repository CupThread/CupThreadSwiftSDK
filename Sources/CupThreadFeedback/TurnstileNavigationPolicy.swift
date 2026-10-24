import Foundation

// MARK: - Hosted-challenge navigation policy (BUG-44)

/// The navigation decision for the hosted Turnstile challenge WebView,
/// extracted from `TurnstileWebView`'s `WKNavigationDelegate` so the
/// nil-frame case is unit-testable without WebKit.
///
/// Main-frame navigation stays pinned to the challenge page's origin via
/// `SameOriginRedirectLimiter.isSameOrigin`, and the widget's own iframe on
/// `challenges.cloudflare.com` stays free to load. The one subtlety is
/// WebKit's frame reporting: **a freshly created `WKWebView` delivers
/// `targetFrame == nil` for its first navigation even when that navigation
/// targets the main frame** — the frame info is not populated until a
/// navigation commits (a long-standing, widely documented quirk; e.g.
/// SO 28151936 / 67814587). Evaluating `targetFrame?.isMainFrame == true`
/// therefore cancels the sheet's own initial `load(_:)` on every fresh
/// presentation, stalling the challenge into the failure watchdog.
///
/// A nil frame is consequently treated as a main-frame navigation and
/// evaluated by the same same-origin check as every committed main-frame
/// load; every genuinely non-nil subframe stays exempt from the origin pin.
/// The policy stays fail-closed: a nil request URL or an off-origin
/// main-frame request is refused.
enum TurnstileNavigationPolicy {
    /// - Parameters:
    ///   - isMainFrame: `navigationAction.targetFrame?.isMainFrame`, where
    ///     `nil` means WebKit has not populated frame info (the first
    ///     navigation of a fresh `WKWebView`) and is handled as a main frame.
    ///   - requestURL: `navigationAction.request.url`; `nil` (no URL to
    ///     evaluate against the pin) is refused for main-frame navigation.
    ///   - challengeURL: the URL the sheet loaded, defining the allowed
    ///     main-frame origin.
    /// - Returns: `true` when the navigation may proceed.
    static func isAllowed(
        isMainFrame: Bool?,
        requestURL: URL?,
        challengeURL: URL
    ) -> Bool {
        guard isMainFrame ?? true else {
            // The widget renders in a `challenges.cloudflare.com` iframe.
            return true
        }
        return SameOriginRedirectLimiter.isSameOrigin(challengeURL, redirectURL: requestURL)
    }
}
