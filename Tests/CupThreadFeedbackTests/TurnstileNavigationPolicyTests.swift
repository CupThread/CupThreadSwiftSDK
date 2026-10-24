import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Hosted-challenge navigation policy (BUG-44)

/// Pins `TurnstileNavigationPolicy`, the extracted decision behind
/// `TurnstileWebView.decidePolicyFor`. The load-bearing case is WebKit's
/// nil `targetFrame` on a fresh `WKWebView`'s first navigation: the old
/// inline policy required `targetFrame?.isMainFrame == true` before the
/// same-origin check, so it cancelled the sheet's own initial `load(_:)`
/// on every fresh presentation and stalled the challenge into the 120 s
/// failure watchdog. A nil frame now takes the same same-origin check as
/// every committed main-frame load, while the policy stays fail-closed.
@Suite("Turnstile navigation policy")
struct TurnstileNavigationPolicyTests {
    private static let challengeURL = URL(string: "https://api.cupthread.com/api/v1/public/apps/k/turnstile/challenge")!
    private static let sameOriginURL = URL(string: "https://api.cupthread.com/turnstile/reload")!
    private static let offOriginURL = URL(string: "https://evil.example.com/turnstile/reload")!

    @Test func nilFrameWithSameOriginRequestIsAllowed() {
        // The fix: WebKit delivers `targetFrame == nil` for the first
        // navigation of a freshly created WKWebView, so the sheet's own
        // initial load must reach the same-origin check and pass it.
        #expect(TurnstileNavigationPolicy.isAllowed(
            isMainFrame: nil,
            requestURL: Self.sameOriginURL,
            challengeURL: Self.challengeURL
        ))
    }

    @Test func nilFrameWithOffOriginRequestIsRefused() {
        #expect(!TurnstileNavigationPolicy.isAllowed(
            isMainFrame: nil,
            requestURL: Self.offOriginURL,
            challengeURL: Self.challengeURL
        ))
    }

    @Test func subframeNavigationIsAllowed() {
        // The widget renders in a `challenges.cloudflare.com` iframe; the
        // origin pin only ever applies to (or nil-detected) main frames.
        #expect(TurnstileNavigationPolicy.isAllowed(
            isMainFrame: false,
            requestURL: Self.offOriginURL,
            challengeURL: Self.challengeURL
        ))
    }

    @Test func mainFrameWithSameOriginRequestIsAllowed() {
        #expect(TurnstileNavigationPolicy.isAllowed(
            isMainFrame: true,
            requestURL: Self.sameOriginURL,
            challengeURL: Self.challengeURL
        ))
    }

    @Test func mainFrameWithOffOriginRequestIsRefused() {
        #expect(!TurnstileNavigationPolicy.isAllowed(
            isMainFrame: true,
            requestURL: Self.offOriginURL,
            challengeURL: Self.challengeURL
        ))
    }

    @Test func mainFrameWithoutRequestURLIsRefused() {
        // Fail-closed: a main-frame (or nil-detected main-frame) navigation
        // with no URL to evaluate against the origin pin is refused.
        #expect(!TurnstileNavigationPolicy.isAllowed(
            isMainFrame: true,
            requestURL: nil,
            challengeURL: Self.challengeURL
        ))
        #expect(!TurnstileNavigationPolicy.isAllowed(
            isMainFrame: nil,
            requestURL: nil,
            challengeURL: Self.challengeURL
        ))
    }
}
