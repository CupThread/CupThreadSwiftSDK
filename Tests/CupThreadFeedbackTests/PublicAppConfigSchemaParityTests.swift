import Foundation
import Testing
@testable import CupThreadFeedback

// Schema-parity tests for `PublicAppConfig` (#397): the live contract carries
// `workspaceSlug` (required) and `appStoreUrl` / `googlePlayUrl` (required-
// nullable), which the SDK historically dropped on the floor.
@Suite("PublicAppConfigSchemaParity", .serialized)
struct PublicAppConfigSchemaParityTests {
    static let apiHost = "config-parity.example.com"

    // MARK: - Client-path decoding

    @Test func fetchAppConfigDecodesWorkspaceSlugAndPerStoreURLs() async throws {
        var payload = makeConfigJSON()
        payload["appStoreUrl"] = "https://apps.apple.com/app/demo"
        payload["googlePlayUrl"] = "https://play.google.com/store/apps/details?id=com.example.demo"
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(), try encodeJSON(payload))
        }

        let config = try await makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!).fetchAppConfig()

        #expect(config.workspaceSlug == "demo-workspace")
        #expect(config.appStoreUrl == URL(string: "https://apps.apple.com/app/demo"))
        #expect(config.googlePlayUrl == URL(string: "https://play.google.com/store/apps/details?id=com.example.demo"))
    }

    // MARK: - Direct decoding

    @Test func decodesWorkspaceSlugRequiredOnTheWire() throws {
        let json = try encodeJSON([
            "appId": "app-1",
            "appKey": "app_testkey123456",
            "slug": "demo-app",
            "workspaceSlug": "acme-workspace",
            "name": "Demo App"
        ])

        let config = try JSONDecoder().decode(PublicAppConfig.self, from: json)

        #expect(config.workspaceSlug == "acme-workspace")
    }

    @Test func missingWorkspaceSlugThrows() throws {
        // `workspaceSlug` is required and non-nullable in the published
        // contract (zod: `z.string().min(2).max(64)`, listed in `required`),
        // so it decodes strictly like the other identity fields (`appId`,
        // `appKey`, `slug`, `name`). The #81 lenient-decoding posture covers
        // unknown *values* and optional keys — not missing required ones.
        // A missing key means the server contract drifted and must surface
        // instead of silently decoding to a sentinel.
        let json = try encodeJSON([
            "appId": "app-1",
            "appKey": "app_testkey123456",
            "slug": "demo-app",
            "name": "Demo App"
        ])

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PublicAppConfig.self, from: json)
        }
    }

    @Test func storeURLsDecodeFromConfiguredTenant() throws {
        let json = try encodeJSON(makeConfigJSON().merging([
            "appStoreUrl": "https://apps.apple.com/app/demo",
            "googlePlayUrl": "https://play.google.com/store/apps/details?id=com.example.demo"
        ]) { _, new in new })

        let config = try JSONDecoder().decode(PublicAppConfig.self, from: json)

        #expect(config.appStoreUrl == URL(string: "https://apps.apple.com/app/demo"))
        #expect(config.googlePlayUrl == URL(string: "https://play.google.com/store/apps/details?id=com.example.demo"))
    }

    @Test func nullStoreURLsDecodeToNilLikeUnconfiguredTenants() throws {
        // The server emits explicit `null` for unconfigured store URLs (the
        // fields are required-nullable), so `NSNull()` must decode to `nil`.
        let json = try encodeJSON(makeConfigJSON())

        let config = try JSONDecoder().decode(PublicAppConfig.self, from: json)

        #expect(config.appStoreUrl == nil)
        #expect(config.googlePlayUrl == nil)
    }

    @Test func absentStoreURLsKeepDecodingForOlderFixtures() throws {
        // Pre-parity payloads (older fixtures, older deploys) omit the keys
        // entirely; the optional fields decode to `nil` (#81 posture).
        let json = try encodeJSON([
            "appId": "app-1",
            "appKey": "app_testkey123456",
            "slug": "demo-app",
            "workspaceSlug": "demo-workspace",
            "name": "Demo App"
        ])

        let config = try JSONDecoder().decode(PublicAppConfig.self, from: json)

        #expect(config.appStoreUrl == nil)
        #expect(config.googlePlayUrl == nil)
    }

    @Test func decodesRequireAnonymousVoteTurnstileWhenPresent() throws {
        let jsonTrue = try encodeJSON(makeConfigJSON().merging(["requireAnonymousVoteTurnstile": true]) { _, new in new })
        let configTrue = try JSONDecoder().decode(PublicAppConfig.self, from: jsonTrue)
        #expect(configTrue.requireAnonymousVoteTurnstile == true)

        let jsonFalse = try encodeJSON(makeConfigJSON().merging(["requireAnonymousVoteTurnstile": false]) { _, new in new })
        let configFalse = try JSONDecoder().decode(PublicAppConfig.self, from: jsonFalse)
        #expect(configFalse.requireAnonymousVoteTurnstile == false)
    }

    @Test func defaultsRequireAnonymousVoteTurnstileToFalseWhenAbsent() throws {
        let json = try encodeJSON(makeConfigJSON())
        let config = try JSONDecoder().decode(PublicAppConfig.self, from: json)
        #expect(config.requireAnonymousVoteTurnstile == false)
    }

    // MARK: - Encoding

    @Test func encodeRoundTripsNewFields() throws {
        let json = try encodeJSON(makeConfigJSON().merging([
            "workspaceSlug": "acme-workspace",
            "appStoreUrl": "https://apps.apple.com/app/demo",
            "requireAnonymousVoteTurnstile": true
        ]) { _, new in new })

        let config = try JSONDecoder().decode(PublicAppConfig.self, from: json)
        let dict = try #require(parseJSONDict(try JSONEncoder().encode(config)))

        #expect(dict["workspaceSlug"] as? String == "acme-workspace")
        #expect(dict["appStoreUrl"] as? String == "https://apps.apple.com/app/demo")
        #expect(dict["googlePlayUrl"] == nil) // nil encodes as key absence, matching the `storeUrl` precedent
        #expect(dict["requireAnonymousVoteTurnstile"] as? Bool == true)
    }

    // MARK: - Source compatibility

    @Test func memberwiseInitDefaultsKeepExistingCallSitesCompiling() {
        // Hosts and tests construct configs without the parity fields; the
        // memberwise defaults must keep that compiling and well-defined.
        let config = PublicAppConfig(
            appId: "app-1",
            appKey: "app_testkey123456",
            slug: "demo-app",
            name: "Demo App"
        )

        #expect(config.workspaceSlug.isEmpty)
        #expect(config.appStoreUrl == nil)
        #expect(config.googlePlayUrl == nil)
        #expect(config.requireAnonymousVoteTurnstile == false)
    }
}
