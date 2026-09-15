import Foundation
import Testing
@testable import CupThreadFeedback

@Suite("LenientDecoding", .serialized)
struct LenientDecodingTests {
    static let apiHost = "lenient-decode.example.com"

    static func makeAPIClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(apiHost)")!)
    }

    // MARK: - PublicAppConfig.allowedPlatforms

    @Test func fetchAppConfigProjectsKnownAndRetainsUnknownPlatformValues() async throws {
        // #81: unknown server enum values (e.g. "visionos", "web") must not throw
        // DecodingError. Known values are projected to FeedbackPlatform, while
        // allowedPlatformValues retains the exact raw server array.
        var payload = makeConfigJSON()
        payload["allowedPlatforms"] = ["ios", "visionos", "macos", "web"]
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(), try encodeJSON(payload))
        }

        let config = try await Self.makeAPIClient().fetchAppConfig()

        #expect(config.allowedPlatforms == [.ios, .macos])
        #expect(config.allowedPlatformValues == ["ios", "visionos", "macos", "web"])
    }

    @Test func fetchAppConfigDecodesKnownPlatformsIdenticalToBefore() async throws {
        // #81 regression guard: standard allowedPlatforms decodes identically.
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(), try encodeJSON(makeConfigJSON()))
        }

        let config = try await Self.makeAPIClient().fetchAppConfig()

        #expect(config.allowedPlatforms == [.ios, .macos])
        #expect(config.allowedPlatformValues == ["ios", "macos"])
    }

    @Test func fetchAppConfigDefaultsAllowedPlatformsWhenMissing() async throws {
        var payload = makeConfigJSON()
        payload.removeValue(forKey: "allowedPlatforms")
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(), try encodeJSON(payload))
        }

        let config = try await Self.makeAPIClient().fetchAppConfig()

        #expect(config.allowedPlatforms.isEmpty)
        #expect(config.allowedPlatformValues.isEmpty)
    }

    @Test func fetchAppConfigPreservesSdkAppearanceWhenUnknownPlatformPresent() async throws {
        // #81: ensure an unknown platform value does not trip decode failure
        // which causes sdk appearance to fail open to .defaults.
        var payload = makeConfigJSON()
        payload["allowedPlatforms"] = ["ios", "visionos"]
        payload["sdk"] = [
            "theme": "ocean",
            "features": [
                "feedback": true,
                "featureRequests": false,
                "roadmap": true,
                "changelog": true
            ],
            "changelogOverlay": [
                "title": "Just shipped",
                "subtitle": "Here's what changed",
                "entryCount": 2,
                "primaryButton": "Got it",
                "closeButton": "Not now"
            ]
        ]
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(), try encodeJSON(payload))
        }

        let config = try await Self.makeAPIClient().fetchAppConfig()

        #expect(config.allowedPlatforms == [.ios])
        #expect(config.allowedPlatformValues == ["ios", "visionos"])
        #expect(config.sdk.theme == .ocean)
        #expect(config.sdk.features.featureRequests == false)
        #expect(config.sdk.features.roadmap == true)
        #expect(config.sdk.changelogOverlay.title == "Just shipped")
        #expect(config.sdk.changelogOverlay.entryCount == 2)
        #expect(config.sdk.changelogOverlay.primaryButton == "Got it")
    }

    @Test func publicAppConfigEncodesPreservingUnknownPlatforms() throws {
        let json = try encodeJSON([
            "appId": "app-1",
            "appKey": "app_testkey123456",
            "slug": "demo-app",
            "name": "Demo App",
            "allowedPlatforms": ["ios", "visionos"]
        ])
        let decoded = try JSONDecoder().decode(PublicAppConfig.self, from: json)
        #expect(decoded.allowedPlatforms == [.ios])
        #expect(decoded.allowedPlatformValues == ["ios", "visionos"])

        let encoded = try JSONEncoder().encode(decoded)
        let dict = try #require(parseJSONDict(encoded))
        #expect(dict["allowedPlatforms"] as? [String] == ["ios", "visionos"])
    }

    // MARK: - BoardColumn.Kind fallback

    @Test func fetchColumnsFallsBackToNormalKindForUnknownColumnKind() async throws {
        // #81: unknown column kinds (e.g. "archived", "icebox") must decode gracefully
        // and fall back to .normal rather than throwing DecodingError.
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            let columns: [[String: Any]] = [
                [
                    "id": "c1",
                    "appId": "app-1",
                    "name": "Archived",
                    "slug": "archived",
                    "position": 0,
                    "isVisible": true,
                    "isSystem": true,
                    "kind": "archived",
                    "createdAt": "2026-01-01T00:00:00.000Z",
                    "updatedAt": "2026-01-01T00:00:00.000Z"
                ],
                [
                    "id": "c2",
                    "appId": "app-1",
                    "name": "Icebox",
                    "slug": "icebox",
                    "position": 1,
                    "isVisible": true,
                    "isSystem": false,
                    "kind": "icebox",
                    "createdAt": "2026-01-01T00:00:00.000Z",
                    "updatedAt": "2026-01-01T00:00:00.000Z"
                ]
            ]
            return (makeHTTPResponse(), try encodeJSON(["columns": columns]))
        }

        let columns = try await Self.makeAPIClient().fetchColumns()
        #expect(columns.count == 2)
        #expect(columns[0].kind == .normal)
        #expect(columns[1].kind == .normal)
    }

    @Test func boardColumnKindDecodesKnownAndFallsBackOnUnknown() throws {
        let decoder = JSONDecoder()

        let pending = try decoder.decode(BoardColumn.Kind.self, from: Data("\"pending_review\"".utf8))
        let normal = try decoder.decode(BoardColumn.Kind.self, from: Data("\"normal\"".utf8))
        let done = try decoder.decode(BoardColumn.Kind.self, from: Data("\"done\"".utf8))
        let unknown = try decoder.decode(BoardColumn.Kind.self, from: Data("\"archived\"".utf8))

        #expect(pending == .pendingReview)
        #expect(normal == .normal)
        #expect(done == .done)
        #expect(unknown == .normal)
    }

    @Test func boardColumnKindEncodesRawValue() throws {
        let encoder = JSONEncoder()

        let pendingData = try encoder.encode(BoardColumn.Kind.pendingReview)
        let string = String(data: pendingData, encoding: .utf8)
        #expect(string == "\"pending_review\"")
    }
}
