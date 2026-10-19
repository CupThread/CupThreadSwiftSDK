import Foundation

// MARK: - Turnstile widget configuration

/// Public Cloudflare Turnstile widget configuration (`turnstile`) from
/// `GET /api/v1/public/config/{appKey}` (SaaS #1052, issue #53).
///
/// Carries the site key native clients render in an embedded `WKWebView`
/// against the portal's hosted challenge page; site keys are public by
/// design. The object is omitted entirely while the deployment publishes no
/// key, so ``PublicAppConfig/turnstile`` being present is the signal that an
/// in-SDK challenge can be presented at all.
public struct TurnstileConfig: Codable, Equatable, Sendable {
    /// The public widget site key (`0x…`), or `nil` while the deployment
    /// publishes none.
    public let siteKey: String?

    /// Creates a Turnstile widget configuration.
    /// - Parameter siteKey: The public widget site key, or `nil`.
    public init(siteKey: String? = nil) {
        self.siteKey = siteKey?.nilIfEmpty
    }

    /// Trims the site key and collapses a blank value to `nil`, so
    /// whitespace-only keys never reach the challenge page.
    func cleaned() -> TurnstileConfig {
        TurnstileConfig(siteKey: siteKey)
    }
}
