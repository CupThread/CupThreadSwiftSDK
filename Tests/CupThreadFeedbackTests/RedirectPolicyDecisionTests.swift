import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Same-origin redirect decision tests (SEC-11, #284)

/// Pins the redirect policy's decision logic in isolation: the origin matcher
/// (`SameOriginRedirectLimiter.isSameOrigin`), the delegate's refuse/follow
/// completion, and the default-session wiring that installs the policy.
/// The end-to-end redirect flows live in `RedirectPolicyTests`.
@Suite("RedirectPolicyDecision")
struct RedirectPolicyDecisionTests {
    private let host = "redirect-policy.example.com"
    private let evilHost = "evil-redirect.example.com"
    private var baseURL: URL { URL(string: "https://\(host)")! }

    // MARK: Origin matching rules

    @Test func sameOriginMatchingRules() {
        let api = URL(string: "https://api.example.com")!

        // Same host, case-insensitive.
        #expect(SameOriginRedirectLimiter.isSameOrigin(api, redirectURL: URL(string: "https://API.example.com/x")!))
        #expect(SameOriginRedirectLimiter.isSameOrigin(
            URL(string: "https://API.EXAMPLE.COM")!,
            redirectURL: api
        ))

        // Explicit default port equals the scheme default.
        #expect(SameOriginRedirectLimiter.isSameOrigin(api, redirectURL: URL(string: "https://api.example.com:443/x")!))
        #expect(SameOriginRedirectLimiter.isSameOrigin(
            URL(string: "http://api.example.com:80/x")!,
            redirectURL: URL(string: "http://api.example.com/y")!
        ))

        // Non-default ports must match exactly.
        #expect(!SameOriginRedirectLimiter.isSameOrigin(api, redirectURL: URL(string: "https://api.example.com:8443/x")!))
        #expect(!SameOriginRedirectLimiter.isSameOrigin(
            URL(string: "https://api.example.com:8443")!,
            redirectURL: URL(string: "https://api.example.com:8444/x")!
        ))

        // Scheme changes are refused — including the https → http downgrade.
        #expect(!SameOriginRedirectLimiter.isSameOrigin(api, redirectURL: URL(string: "http://api.example.com/x")!))
        #expect(!SameOriginRedirectLimiter.isSameOrigin(
            URL(string: "http://api.example.com")!,
            redirectURL: URL(string: "https://api.example.com/x")!
        ))

        // Other hosts are refused — including suffix and subdomain tricks.
        #expect(!SameOriginRedirectLimiter.isSameOrigin(api, redirectURL: URL(string: "https://evil.example.com/")!))
        #expect(!SameOriginRedirectLimiter.isSameOrigin(api, redirectURL: URL(string: "https://api.example.com.evil.com/")!))
        #expect(!SameOriginRedirectLimiter.isSameOrigin(api, redirectURL: URL(string: "https://evil-api.example.com/")!))
        #expect(!SameOriginRedirectLimiter.isSameOrigin(
            URL(string: "https://api.example.com")!,
            redirectURL: URL(string: "https://sub.api.example.com/")!
        ))

        // Missing URLs or unusable origins never match.
        #expect(!SameOriginRedirectLimiter.isSameOrigin(nil, redirectURL: api))
        #expect(!SameOriginRedirectLimiter.isSameOrigin(api, redirectURL: nil))
        #expect(!SameOriginRedirectLimiter.isSameOrigin(api, redirectURL: URL(string: "mailto:user@example.com")))
    }

    // MARK: Delegate decision

    /// Pins the delegate's decision directly: a cross-origin redirect gets
    /// `nil` (refused; URLSession then delivers the 3xx as the final
    /// response), a same-origin one gets the proposed request (followed).
    /// This exercises the refusal path that the URLProtocol simulation above
    /// cannot drive end-to-end.
    @Test func redirectDelegateRefusesCrossOriginAndAllowsSameOrigin() throws {
        let limiter = SameOriginRedirectLimiter()
        let originalURL = URL(string: "https://\(host)/api/v1/uploads/upl-rp-1")!
        let response = HTTPURLResponse(
            url: originalURL,
            statusCode: 307,
            httpVersion: nil,
            headerFields: nil
        )!

        func decision(for redirectURL: String?) throws -> (called: Bool, followedRequest: URLRequest?) {
            var original = URLRequest(url: originalURL)
            original.httpMethod = "PUT"
            original.setValue("Bearer stok-rp", forHTTPHeaderField: "Authorization")
            // An unstarted task carries its `originalRequest`, which is all
            // the delegate reads from it.
            let task = URLSession.shared.dataTask(with: original)
            defer { task.cancel() }
            let proposed = redirectURL.map { URLRequest(url: URL(string: $0)!) }

            let followedBox = CaptureBox<URLRequest?>()
            let calledBox = CaptureBox<Bool>()
            limiter.urlSession(
                URLSession.shared,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: proposed ?? URLRequest(url: originalURL),
                completionHandler: { followed in
                    calledBox.value = true
                    followedBox.value = followed
                }
            )
            return (calledBox.value == true, followedBox.value ?? nil)
        }

        // Cross-origin: refused — no request handed back to URLSession.
        let refused = try decision(for: "https://\(evilHost)/steal")
        #expect(refused.called)
        #expect(refused.followedRequest == nil)

        // Same-origin: followed with the proposed request.
        let followed = try decision(for: "https://\(host)/api/v1/uploads/upl-rp-1/content")
        #expect(followed.called)
        #expect(followed.followedRequest?.url == URL(string: "https://\(host)/api/v1/uploads/upl-rp-1/content"))
    }

    // MARK: Default session wiring

    @Test func clientsWithoutInjectedSessionShareTheRedirectSafeDefaultSession() {
        let configuration = FeedbackClientConfiguration(baseURL: baseURL, appKey: "app_redirectpol")
        let plainClient = FeedbackClient(configuration: configuration)
        let anotherClient = FeedbackClient(configuration: configuration)

        #expect(plainClient.session === FeedbackClient.defaultSession)
        #expect(anotherClient.session === FeedbackClient.defaultSession)
    }
}
