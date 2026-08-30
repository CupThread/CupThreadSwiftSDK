import Foundation
import Testing
@testable import CupThreadFeedback

// All network tests share the static MockURLProtocol handler, so they run serialized.
// This suite uses its own base host so it can run in parallel with the FeedbackClient suite.
@Suite("PublicAPI", .serialized)
struct PublicAPITests {
    static let apiHost = "publicapi.example.com"

    static func makeAPIClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(apiHost)")!)
    }

    // MARK: - App config

    @Test func fetchAppConfigHitsConfigEndpoint() async throws {
        let capture = CaptureBox<URL>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request.url
            return (makeHTTPResponse(), try encodeJSON(makeConfigJSON()))
        }

        _ = try await Self.makeAPIClient().fetchAppConfig()

        let url = try #require(capture.value)
        #expect(url.path == "/api/v1/public/config/app_testkey123456")
    }

    @Test func fetchAppConfigDecodesAllFields() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(), try encodeJSON(makeConfigJSON()))
        }

        let config = try await Self.makeAPIClient().fetchAppConfig()

        #expect(config.appId == "app-1")
        #expect(config.name == "Demo App")
        #expect(config.allowPublic == true)
        #expect(config.allowedPlatforms == [.ios, .macos])
        #expect(config.maxAttachmentBytes == 20_000_000)
        #expect(config.allowAnonymousRoadmap == true)
        #expect(config.allowAnonymousVote == false)
        #expect(config.allowAnonymousFeedback == true)
        #expect(config.allowAnonymousChangelog == true)
        #expect(config.sdk.theme == .system)
        #expect(config.sdk.features.changelog == true)
        #expect(config.sdk.changelogOverlay.entryCount == 3)
        #expect(config.iconUrl == URL(string: "https://example.com/icon.png"))
    }

    @Test func fetchAppConfigDecodesSdkAppearance() async throws {
        var payload = makeConfigJSON()
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
        #expect(config.sdk.theme == .ocean)
        #expect(config.sdk.features.featureRequests == false)
        #expect(config.sdk.changelogOverlay.title == "Just shipped")
        #expect(config.sdk.changelogOverlay.entryCount == 2)
        #expect(config.sdk.changelogOverlay.primaryButton == "Got it")
    }

    @Test func prepareChangelogOverlayReturnsNilWhenHidden() async throws {
        var payload = makeConfigJSON()
        payload["sdk"] = [
            "theme": "system",
            "features": ["changelog": false],
            "changelogOverlay": ["title": "What's New", "entryCount": 3]
        ]
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            if request.url?.path.contains("/changelog") == true {
                return (makeHTTPResponse(), try encodeJSON(["entries": [Any]()]))
            }
            return (makeHTTPResponse(), try encodeJSON(payload))
        }

        let prepared = try await Self.makeAPIClient().prepareChangelogOverlay()
        #expect(prepared == nil)
    }

    @Test func prepareChangelogOverlayLimitsEntries() async throws {
        var payload = makeConfigJSON()
        payload["sdk"] = [
            "theme": "sunset",
            "features": ["changelog": true],
            "changelogOverlay": ["title": "New", "entryCount": 1]
        ]
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            if request.url?.path.contains("/changelog") == true {
                return (makeHTTPResponse(), try encodeJSON([
                    "entries": [
                        [
                            "id": "e2",
                            "title": "New",
                            "body": "",
                            "versionLabel": "1.1",
                            "publishedAt": "2026-02-01T00:00:00.000Z",
                            "linkedRequests": []
                        ],
                        [
                            "id": "e1",
                            "title": "Old",
                            "body": "",
                            "versionLabel": "1.0",
                            "publishedAt": "2026-01-01T00:00:00.000Z",
                            "linkedRequests": []
                        ]
                    ]
                ]))
            }
            return (makeHTTPResponse(), try encodeJSON(payload))
        }

        let prepared = try await Self.makeAPIClient().prepareChangelogOverlay()
        #expect(prepared?.entries.map(\.id) == ["e2"])
        #expect(prepared?.appearance.theme == .sunset)
    }

    @Test func fetchAppConfigThrowsOn404() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 404), try encodeJSON(["error": "App not found"]))
        }

        do {
            _ = try await Self.makeAPIClient().fetchAppConfig()
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            if case .unexpectedStatus(let code, _) = error {
                #expect(code == 404)
            } else {
                Issue.record("Unexpected error type: \(error)")
            }
        }
    }

    // MARK: - Columns

    @Test func fetchColumnsHitsColumnsEndpointAndSortsByPosition() async throws {
        let capture = CaptureBox<URL>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request.url
            let columns = [
                makeColumnJSON(id: "c2", name: "In Progress", slug: "in-progress", position: 1),
                makeColumnJSON(id: "c1", name: "Backlog", slug: "backlog", position: 0),
                makeColumnJSON(id: "c3", name: "Done", slug: "done", position: 2)
            ]
            return (makeHTTPResponse(), try encodeJSON(["columns": columns]))
        }

        let columns = try await Self.makeAPIClient().fetchColumns()

        let url = try #require(capture.value)
        #expect(url.path == "/api/v1/public/columns/app_testkey123456")
        #expect(columns.map(\.id) == ["c1", "c2", "c3"])
        #expect(columns.first?.kind == .pendingReview)
        #expect(columns.last?.kind == .done)
    }

    // MARK: - Versions

    @Test func fetchVersionsHitsVersionsEndpointAndSortsByPosition() async throws {
        let capture = CaptureBox<URL>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request.url
            let versions = [
                makeVersionJSON(id: "v2", label: "2.1", position: 1),
                makeVersionJSON(id: "v1", label: "2.0", position: 0)
            ]
            return (makeHTTPResponse(), try encodeJSON(["versions": versions]))
        }

        let versions = try await Self.makeAPIClient().fetchVersions()

        let url = try #require(capture.value)
        #expect(url.path == "/api/v1/public/versions/app_testkey123456")
        #expect(versions.map(\.id) == ["v1", "v2"])
        #expect(versions.first?.released == true)
        #expect(versions.first?.releasedAt == "2026-01-15T00:00:00.000Z")
    }

    // MARK: - X-User-Token on feedback submit

    @Test func submitSetsUserTokenHeaderWhenProvided() async throws {
        let capture = CaptureBox<String?>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request.value(forHTTPHeaderField: "X-User-Token")
            return (makeHTTPResponse(), try encodeJSON(["submissionId": "s-1", "forwardedToGithub": true]))
        }

        let token = UUID().uuidString
        _ = try await Self.makeAPIClient().submit(
            FeedbackDraft(title: "T", description: "Desc ok", platform: .ios),
            userToken: token
        )

        #expect(capture.value == token)
    }

    @Test func submitOmitsUserTokenHeaderWhenNil() async throws {
        let capture = CaptureBox<String>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            // "" is a sentinel for an absent header (avoids the double-optional trap).
            capture.value = request.value(forHTTPHeaderField: "X-User-Token") ?? ""
            return (makeHTTPResponse(), try encodeJSON(["submissionId": "s-1", "forwardedToGithub": true]))
        }

        _ = try await Self.makeAPIClient().submit(FeedbackDraft(title: "T", description: "Desc ok", platform: .ios))

        #expect(capture.value == "")
    }

    // MARK: - Feature request list query

    @Test func fetchFeatureRequestsIncludesVersionIdFilterWhenProvided() async throws {
        let capture = CaptureBox<URL>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request.url
            return (makeHTTPResponse(), try encodeJSON(["requests": [], "total": 0]))
        }

        _ = try await Self.makeAPIClient().fetchFeatureRequests(
            userToken: UUID().uuidString,
            versionId: "v-42"
        )

        let url = try #require(capture.value)
        #expect(url.path == "/api/v1/feature-requests")
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems)
        #expect(query.contains(URLQueryItem(name: "versionId", value: "v-42")))
    }

    // MARK: - FeatureRequestItem decoding (server shape)

    @Test func featureRequestItemDecodesServerRecord() throws {
        let json = """
        {
            "id": "fr-1",
            "appId": "app-1",
            "title": "Dark mode",
            "description": "Please add dark mode",
            "status": "in-progress",
            "columnId": "c2",
            "columnSlug": "in-progress",
            "columnName": "In Progress",
            "versionId": "v1",
            "versionLabel": "2.1",
            "releasedVersion": "2.1",
            "requesterName": "Lex",
            "approved": true,
            "voteCount": 7,
            "hasVoted": true,
            "isOwnRequest": false,
            "createdAt": "2026-01-01T00:00:00.000Z",
            "updatedAt": "2026-02-01T00:00:00.000Z"
        }
        """.data(using: .utf8)!

        let item = try JSONDecoder().decode(FeatureRequestItem.self, from: json)

        #expect(item.title == "Dark mode")
        #expect(item.status == "in-progress")
        #expect(item.columnName == "In Progress")
        #expect(item.stageName == "In Progress")
        #expect(item.versionLabel == "2.1")
        #expect(item.voteCount == 7)
        #expect(item.hasVoted == true)
    }

    @Test func featureRequestItemDecodesCustomStatusWithoutColumn() throws {
        // Free-form status (custom column name) must not break decoding.
        let json = """
        {
            "id": "fr-2",
            "appId": "app-1",
            "title": "Widgets",
            "description": "Add widgets",
            "status": "Under Investigation",
            "columnId": null,
            "columnSlug": null,
            "columnName": null,
            "versionId": null,
            "versionLabel": null,
            "releasedVersion": null,
            "requesterName": null,
            "approved": true,
            "voteCount": 0,
            "hasVoted": false,
            "isOwnRequest": false,
            "createdAt": "2026-01-01T00:00:00.000Z",
            "updatedAt": "2026-01-01T00:00:00.000Z"
        }
        """.data(using: .utf8)!

        let item = try JSONDecoder().decode(FeatureRequestItem.self, from: json)

        #expect(item.status == "Under Investigation")
        #expect(item.stageName == "Under Investigation")
        #expect(item.columnId == nil)
    }

    @Test func withVoteStateUpdatesVoteFieldsOnly() throws {
        let base = FeatureRequestItem(
            id: "fr-1",
            appId: "app-1",
            title: "T",
            description: "D",
            status: "backlog",
            columnName: "Backlog",
            approved: true,
            voteCount: 3,
            hasVoted: false,
            isOwnRequest: false,
            createdAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-01-01T00:00:00.000Z"
        )

        let updated = base.withVoteState(voted: true, count: 4)

        #expect(updated.voteCount == 4)
        #expect(updated.hasVoted == true)
        #expect(updated.title == base.title)
        #expect(updated.columnName == base.columnName)
    }
}

// MARK: - JSON fixtures

private func makeConfigJSON() -> [String: Any] {
    [
        "appId": "app-1",
        "appKey": "app_testkey123456",
        "slug": "demo-app",
        "name": "Demo App",
        "storeUrl": NSNull(),
        "storeKind": NSNull(),
        "iconUrl": "https://example.com/icon.png",
        "allowPublic": true,
        "allowedPlatforms": ["ios", "macos"],
        "maxAttachmentBytes": 20_000_000,
        "allowAnonymousRoadmap": true,
        "allowAnonymousVote": false,
        "allowAnonymousFeedback": true
    ]
}

private func makeColumnJSON(id: String, name: String, slug: String, position: Int) -> [String: Any] {
    [
        "id": id,
        "appId": "app-1",
        "name": name,
        "slug": slug,
        "position": position,
        "isVisible": true,
        "isSystem": true,
        "kind": slug == "done" ? "done" : (slug == "backlog" ? "pending_review" : "normal"),
        "createdAt": "2026-01-01T00:00:00.000Z",
        "updatedAt": "2026-01-01T00:00:00.000Z"
    ]
}

private func makeVersionJSON(id: String, label: String, position: Int) -> [String: Any] {
    [
        "id": id,
        "appId": "app-1",
        "label": label,
        "position": position,
        "released": true,
        "releasedAt": "2026-01-15T00:00:00.000Z",
        "description": NSNull(),
        "createdAt": "2026-01-01T00:00:00.000Z",
        "updatedAt": "2026-01-01T00:00:00.000Z"
    ]
}
