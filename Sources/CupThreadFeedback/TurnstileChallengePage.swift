import Foundation

// MARK: - Hosted challenge page (#53 Phase 2, SaaS #1052)

/// Builds the portal's hosted Turnstile challenge page URL for a widget
/// binding.
///
/// The page is a static, framework-free document served by the CupThread
/// portal (`…/turnstile/verify`); it renders the widget with the parameters
/// below and bridges the minted token back to whichever native host presents
/// it. Tokens are single-use and short-lived, so the page is opened — and the
/// token consumed — once per gated call.
extension FeedbackClientConfiguration {
    /// The hosted challenge page for a widget binding, with the widget
    /// parameters on the query string.
    ///
    /// - Parameters:
    ///   - challenge: The `(action, cdata)` binding the endpoint verifies —
    ///     ``TurnstileChallenge/feedback(appKey:)`` for feedback intake and
    ///     attachment upload sessions, ``TurnstileChallenge/featureRequest(appKey:)``
    ///     for proposals. A token minted under a different binding is rejected
    ///     by the server, so this mirrors the binding the failing call used.
    ///   - siteKey: The public site key from ``PublicAppConfig/turnstile``.
    ///   - theme: The portal-chosen theme; named palettes that follow the
    ///     system appearance map to the widget's `auto`.
    ///   - locale: The locale for the widget's own copy.
    /// - Returns: The challenge page URL, or `nil` when the site key is blank
    ///   or a URL cannot be assembled.
    public func makeTurnstileChallengeURL(
        for challenge: TurnstileChallenge,
        siteKey: String,
        theme: SdkTheme = .system,
        locale: Locale = .current
    ) -> URL? {
        guard let siteKey = siteKey.nilIfEmpty else { return nil }
        let page = turnstileChallengeURL ?? Self.derivedTurnstileChallengeURL(from: baseURL)
        guard let page, var components = URLComponents(url: page, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var queryItems = [
            URLQueryItem(name: "siteKey", value: siteKey),
            URLQueryItem(name: "action", value: challenge.action),
            URLQueryItem(name: "cdata", value: challenge.cdata)
        ]
        if let widgetTheme = theme.turnstileWidgetTheme {
            queryItems.append(URLQueryItem(name: "theme", value: widgetTheme))
        }
        if let language = locale.turnstileLanguageTag {
            queryItems.append(URLQueryItem(name: "locale", value: language))
        }
        components.queryItems = queryItems
        return components.url
    }

    /// The challenge page on the portal origin derived from ``baseURL``: a
    /// leading `api.` host label becomes `app.` (`https://api.cupthread.com` →
    /// `https://app.cupthread.com/turnstile/verify`), and any other host keeps
    /// its origin.
    ///
    /// Deployment-specific portals — or a self-hosted API origin whose portal
    /// lives elsewhere — pass ``turnstileChallengeURL`` instead.
    static func derivedTurnstileChallengeURL(from baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let host = components.host?.nilIfEmpty else {
            return nil
        }
        components.host = host.hasPrefix("api.") ? "app." + host.dropFirst("api.".count) : host
        components.path = "/turnstile/verify"
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

extension SdkTheme {
    /// The widget `theme` parameter for this preset, or `nil` for `auto`.
    var turnstileWidgetTheme: String? {
        switch preferredColorScheme {
        case .light: return "light"
        case .dark: return "dark"
        default: return nil
        }
    }
}

extension Locale {
    /// The widget `language` parameter for this locale — `zh-CN`, `en-US`,
    /// `de` — or `nil` when the language has no identifier.
    var turnstileLanguageTag: String? {
        guard let code = language.languageCode?.identifier else { return nil }
        guard let region = language.region?.identifier else { return code }
        return "\(code)-\(region)"
    }
}

// MARK: - Presentation seam

/// A hosted challenge ready to present, resolved from a client and the app
/// configuration.
///
/// Handed out by
/// ``FeedbackClient/turnstileChallengePresentation(for:config:theme:locale:)``
/// when an intake call was rejected by the human-verification gate and the
/// SDK can resolve it with ``TurnstileChallengeSheet``.
public struct TurnstileChallengePresentation: Equatable, Sendable {
    /// The widget binding the minted token will carry.
    public let challenge: TurnstileChallenge
    /// The hosted challenge page to load in the sheet's web view.
    public let url: URL

    /// Creates a presentation from an explicit binding and page URL.
    public init(challenge: TurnstileChallenge, url: URL) {
        self.challenge = challenge
        self.url = url
    }
}

extension FeedbackClient {
    /// Whether this client resolves a `turnstileRequired` rejection with the
    /// SDK's hosted challenge sheet: no `turnstileTokenProvider`
    /// is installed (a provider owns its own retry path) and the platform
    /// provides WebKit. The app configuration must also publish a site key —
    /// call ``turnstileChallengePresentation(for:config:theme:locale:)`` for
    /// the per-attempt answer.
    public var supportsTurnstileChallengeSheet: Bool {
        !canPresentTurnstileToken && Self.platformSupportsTurnstileChallengeSheet
    }

    /// Resolves the challenge sheet presentation for a rejected intake call.
    ///
    /// Call this after a submission throws
    /// ``FeedbackClientError/turnstileRequired(message:requestId:)``: a
    /// non-`nil` result means the SDK can present the hosted challenge and
    /// resubmit with the minted token.
    ///
    /// - Parameters:
    ///   - challenge: The binding of the rejected call.
    ///   - config: The app configuration carrying ``PublicAppConfig/turnstile``
    ///     — normally the config the surface already renders with.
    ///   - theme: The theme applied to the SDK surfaces.
    ///   - locale: The locale for the widget's copy.
    /// - Returns: The presentation, or `nil` when a token provider is
    ///   installed, the platform has no WebKit, or no site key is published.
    public func turnstileChallengePresentation(
        for challenge: TurnstileChallenge,
        config: PublicAppConfig?,
        theme: SdkTheme = .system,
        locale: Locale = .current
    ) -> TurnstileChallengePresentation? {
        guard !canPresentTurnstileToken,
              Self.platformSupportsTurnstileChallengeSheet,
              let siteKey = config?.turnstile?.siteKey,
              let url = configuration.makeTurnstileChallengeURL(for: challenge, siteKey: siteKey, theme: theme, locale: locale)
        else { return nil }
        return TurnstileChallengePresentation(challenge: challenge, url: url)
    }

    /// Whether this build can render the hosted challenge: WebKit exists on
    /// iOS, macOS, and visionOS, and not on tvOS.
    static var platformSupportsTurnstileChallengeSheet: Bool {
        #if canImport(WebKit) && !os(tvOS)
        return true
        #else
        return false
        #endif
    }
}
