import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Hosted Turnstile challenge page (#53 Phase 2, SaaS #1052)

/// Pins the native half of the cross-SDK Turnstile contract the SaaS platform
/// shipped in `CupThread/SaaS#1086`: the optional `turnstile.siteKey` public
/// config object, the hosted challenge page's query-string binding, and the
/// bridge messages the page posts back to the WebView host.
@Suite("Turnstile challenge page")
struct TurnstileChallengePageTests {
    // MARK: - Config schema parity

    @Test func configDecodesNestedSiteKey() throws {
        var payload = makeConfigJSON()
        payload["turnstile"] = ["siteKey": "0x4AAAAAAEjuefEg2BPcKFO0"]

        let config = try JSONDecoder().decode(PublicAppConfig.self, from: try encodeJSON(payload))

        #expect(config.turnstile?.siteKey == "0x4AAAAAAEjuefEg2BPcKFO0")
    }

    @Test func configWithoutTurnstileDecodesToNil() throws {
        let config = try JSONDecoder().decode(PublicAppConfig.self, from: try encodeJSON(makeConfigJSON()))

        #expect(config.turnstile == nil)
    }

    @Test func configWithNullSiteKeyKeepsObjectButDropsKey() throws {
        var payload = makeConfigJSON()
        payload["turnstile"] = ["siteKey": NSNull()]

        let config = try JSONDecoder().decode(PublicAppConfig.self, from: try encodeJSON(payload))

        #expect(config.turnstile != nil)
        #expect(config.turnstile?.siteKey == nil)
    }

    @Test func whitespaceSiteKeyCollapsesToNil() throws {
        var payload = makeConfigJSON()
        payload["turnstile"] = ["siteKey": "    "]

        let config = try JSONDecoder().decode(PublicAppConfig.self, from: try encodeJSON(payload))

        #expect(config.turnstile?.siteKey == nil)
    }

    @Test func configRoundTripsTurnstileObject() throws {
        let config = PublicAppConfig(
            appId: "app-1",
            appKey: "app_testkey123456",
            slug: "demo-app",
            name: "Demo App",
            turnstile: TurnstileConfig(siteKey: "0xsitekey")
        )

        let decoded = try JSONDecoder().decode(PublicAppConfig.self, from: JSONEncoder().encode(config))

        #expect(decoded.turnstile == TurnstileConfig(siteKey: "0xsitekey"))
    }

    // MARK: - Challenge page URL

    private func configuration(
        baseURL: String = "https://api.cupthread.com",
        challengeURL: String? = nil
    ) -> FeedbackClientConfiguration {
        FeedbackClientConfiguration(
            baseURL: URL(string: baseURL)!,
            appKey: "app_testkey123456",
            turnstileChallengeURL: challengeURL.flatMap(URL.init(string:))
        )
    }

    private func queryItems(of url: URL) throws -> [String: String] {
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = (components.queryItems ?? []).compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        }
        return Dictionary(uniqueKeysWithValues: items)
    }

    @Test func derivesPortalChallengePageFromCupThreadAPIHost() throws {
        let url = try #require(configuration().makeTurnstileChallengeURL(
            for: .feedback(appKey: "app_testkey123456"),
            siteKey: "0xsitekey",
            theme: .dark,
            locale: Locale(identifier: "en_US")
        ))

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "app.cupthread.com")
        #expect(components.path == "/turnstile/verify")

        let items = try queryItems(of: url)
        #expect(items["siteKey"] == "0xsitekey")
        #expect(items["action"] == TurnstileAction.feedback)
        #expect(items["cdata"] == "app_testkey123456")
        #expect(items["theme"] == "dark")
        #expect(items["locale"] == "en-US")
    }

    @Test func featureRequestBindingUsesItsOwnAction() throws {
        let url = try #require(configuration().makeTurnstileChallengeURL(
            for: .featureRequest(appKey: "app_testkey123456"),
            siteKey: "0xsitekey",
            locale: Locale(identifier: "ja_JP")
        ))

        let items = try queryItems(of: url)
        #expect(items["action"] == TurnstileAction.featureRequest)
        #expect(items["locale"] == "ja-JP")
    }

    @Test func explicitChallengeURLOverrideWins() throws {
        let url = try #require(configuration(
            challengeURL: "https://verify.example.com/custom/human-check"
        ).makeTurnstileChallengeURL(
            for: .feedback(appKey: "app_testkey123456"),
            siteKey: "0xsitekey"
        ))

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "verify.example.com")
        #expect(components.path == "/custom/human-check")
        #expect(try queryItems(of: url)["siteKey"] == "0xsitekey")
    }

    @Test func nonAPHostKeepsItsOwnOrigin() throws {
        let url = try #require(configuration(baseURL: "https://feedback.example.com").makeTurnstileChallengeURL(
            for: .feedback(appKey: "app_testkey123456"),
            siteKey: "0xsitekey"
        ))

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "feedback.example.com")
        #expect(components.path == "/turnstile/verify")
    }

    @Test func explicitPortAndSchemeArePreserved() throws {
        let url = try #require(configuration(baseURL: "http://127.0.0.1:8765").makeTurnstileChallengeURL(
            for: .feedback(appKey: "app_testkey123456"),
            siteKey: "0xsitekey"
        ))

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "http")
        #expect(components.host == "127.0.0.1")
        #expect(components.port == 8765)
    }

    @Test func systemFollowingThemesOmitThemeParameter() throws {
        for theme in [SdkTheme.system, .ocean, .forest, .sunset, .candy] {
            let url = try #require(configuration().makeTurnstileChallengeURL(
                for: .feedback(appKey: "app_testkey123456"),
                siteKey: "0xsitekey",
                theme: theme
            ))
            #expect(try queryItems(of: url)["theme"] == nil, "\(theme) follows the system appearance")
        }
        for theme in [SdkTheme.light, .dark, .midnight] {
            let url = try #require(configuration().makeTurnstileChallengeURL(
                for: .feedback(appKey: "app_testkey123456"),
                siteKey: "0xsitekey",
                theme: theme
            ))
            #expect(try queryItems(of: url)["theme"] == (theme == .light ? "light" : "dark"))
        }
    }

    @Test func blankSiteKeyReturnsNil() {
        #expect(configuration().makeTurnstileChallengeURL(
            for: .feedback(appKey: "app_testkey123456"),
            siteKey: "   "
        ) == nil)
    }

    // MARK: - Bridge messages

    @Test func parsesSuccessToken() {
        #expect(TurnstileBridgeMessage.parse(["status": "success", "token": "tok_123"]) == .token("tok_123"))
    }

    @Test func parsesErrorCodeAsStringAndNumber() {
        #expect(TurnstileBridgeMessage.parse(["status": "error", "code": "110200"]) == .failure(code: "110200"))
        #expect(TurnstileBridgeMessage.parse(["status": "error", "code": 110200]) == .failure(code: "110200"))
        #expect(TurnstileBridgeMessage.parse(["status": "error"]) == .failure(code: nil))
    }

    @Test func parsesExpiredAndRejectsUnusablePayloads() {
        #expect(TurnstileBridgeMessage.parse(["status": "expired"]) == .expired)
        #expect(TurnstileBridgeMessage.parse(["status": "success"]) == nil)
        #expect(TurnstileBridgeMessage.parse(["status": "success", "token": "  "]) == nil)
        #expect(TurnstileBridgeMessage.parse(["token": "tok"]) == nil)
        #expect(TurnstileBridgeMessage.parse(["status": "unknown"]) == nil)
        #expect(TurnstileBridgeMessage.parse("not a dictionary") == nil)
    }

    // MARK: - Sheet rendering

    @Test @MainActor func sheetStartsInLoadingPhaseAndRenders() {
        #if canImport(WebKit) && !os(tvOS)
        let sheet = TurnstileChallengeSheet(
            challengeURL: URL(string: "https://app.cupthread.com/turnstile/verify?siteKey=0xkey")!,
            onVerified: { _ in },
            onCancel: {}
        )

        #expect(sheet.currentPhase == .loading)
        _ = sheet.body
        #endif
    }

    // MARK: - Presentation resolution

    private func makeClient(
        challengeURL: URL? = nil,
        turnstileTokenProvider: (@Sendable (TurnstileChallenge) async -> String?)? = nil
    ) -> FeedbackClient {
        FeedbackClient(
            configuration: FeedbackClientConfiguration(
                baseURL: URL(string: "https://turnstile-page.example.com")!,
                appKey: "app_testkey123456",
                turnstileChallengeURL: challengeURL
            ),
            session: makeMockSession(),
            turnstileTokenProvider: turnstileTokenProvider
        )
    }

    private func makeConfig(siteKey: String?) -> PublicAppConfig {
        PublicAppConfig(
            appId: "app-1",
            appKey: "app_testkey123456",
            slug: "demo-app",
            name: "Demo App",
            turnstile: siteKey.map { TurnstileConfig(siteKey: $0) }
        )
    }

    @Test func presentationResolvesWithoutProviderAndWithSiteKey() throws {
        #if canImport(WebKit) && !os(tvOS)
        let client = makeClient()
        let presentation = try #require(client.turnstileChallengePresentation(
            for: .feedback(appKey: "app_testkey123456"),
            config: makeConfig(siteKey: "0xsitekey"),
            theme: .light,
            locale: Locale(identifier: "en_US")
        ))

        #expect(presentation.challenge == .feedback(appKey: "app_testkey123456"))
        #expect(try queryItems(of: presentation.url)["siteKey"] == "0xsitekey")
        #expect(client.supportsTurnstileChallengeSheet)
        #else
        #expect(makeClient().supportsTurnstileChallengeSheet == false)
        #endif
    }

    @Test func presentationIsUnavailableWhenProviderIsInstalled() {
        let client = makeClient(turnstileTokenProvider: { _ in "host-token" })

        #expect(client.turnstileChallengePresentation(
            for: .feedback(appKey: "app_testkey123456"),
            config: makeConfig(siteKey: "0xsitekey")
        ) == nil)
    }

    @Test func presentationIsUnavailableWithoutPublishedSiteKey() {
        let client = makeClient()

        #expect(client.turnstileChallengePresentation(
            for: .feedback(appKey: "app_testkey123456"),
            config: makeConfig(siteKey: nil)
        ) == nil)
        #expect(client.turnstileChallengePresentation(
            for: .feedback(appKey: "app_testkey123456"),
            config: makeConfig(siteKey: "  ")
        ) == nil)
        #expect(client.turnstileChallengePresentation(
            for: .feedback(appKey: "app_testkey123456"),
            config: nil
        ) == nil)
    }
}
