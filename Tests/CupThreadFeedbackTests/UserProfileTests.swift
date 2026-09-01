import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Models

@Suite("UserProfileModels")
struct UserProfileModelsTests {
    @Test func userProfileDecodesWithAllFields() throws {
        let json = Data("""
        {
            "clerkUserId": "user_123",
            "displayName": "Lex",
            "avatarUrl": "https://example.com/avatar.png",
            "bio": "Developer",
            "websiteUrl": "https://example.com",
            "hideComments": false,
            "createdAt": "2026-01-01T00:00:00.000Z",
            "updatedAt": "2026-01-02T00:00:00.000Z"
        }
        """.utf8)

        let profile = try JSONDecoder().decode(UserProfile.self, from: json)
        #expect(profile.clerkUserId == "user_123")
        #expect(profile.displayName == "Lex")
        #expect(profile.avatarUrl == "https://example.com/avatar.png")
        #expect(profile.bio == "Developer")
        #expect(profile.websiteUrl == "https://example.com")
        #expect(profile.hideComments == false)
        #expect(profile.createdAt == "2026-01-01T00:00:00.000Z")
        #expect(profile.updatedAt == "2026-01-02T00:00:00.000Z")
    }

    @Test func userProfileDecodesWithRequiredFieldsOnly() throws {
        let json = Data("""
        {
            "clerkUserId": "user_456",
            "hideComments": true
        }
        """.utf8)

        let profile = try JSONDecoder().decode(UserProfile.self, from: json)
        #expect(profile.clerkUserId == "user_456")
        #expect(profile.displayName == nil)
        #expect(profile.avatarUrl == nil)
        #expect(profile.bio == nil)
        #expect(profile.websiteUrl == nil)
        #expect(profile.hideComments == true)
        #expect(profile.createdAt == nil)
        #expect(profile.updatedAt == nil)
    }

    @Test func publicUserProfileResponseDecodes() throws {
        let json = Data("""
        {
            "profile": {
                "clerkUserId": "user_1",
                "hideComments": false
            },
            "apps": [],
            "recentComments": [],
            "hideComments": false
        }
        """.utf8)

        let response = try JSONDecoder().decode(PublicUserProfileResponse.self, from: json)
        #expect(response.profile.clerkUserId == "user_1")
        #expect(response.apps.isEmpty)
        #expect(response.recentComments.isEmpty)
        #expect(response.hideComments == false)
    }

    @Test func publicAppSummaryDecodes() throws {
        let json = Data("""
        {
            "id": "app-1",
            "name": "App One",
            "slug": "app-one",
            "iconUrl": "https://example.com/icon.png",
            "description": "An app",
            "requestCount": 42
        }
        """.utf8)

        let app = try JSONDecoder().decode(PublicAppSummary.self, from: json)
        #expect(app.id == "app-1")
        #expect(app.name == "App One")
        #expect(app.slug == "app-one")
        #expect(app.iconUrl == "https://example.com/icon.png")
        #expect(app.description == "An app")
        #expect(app.requestCount == 42)
    }

    @Test func userProfileCommentDecodes() throws {
        let json = Data("""
        {
            "id": "c-1",
            "body": "Hello",
            "createdAt": "2026-01-01T00:00:00.000Z",
            "featureRequestId": "fr-1",
            "featureRequestTitle": "Title",
            "appId": "app-1",
            "appName": "App One"
        }
        """.utf8)

        let comment = try JSONDecoder().decode(UserProfileComment.self, from: json)
        #expect(comment.id == "c-1")
        #expect(comment.body == "Hello")
        #expect(comment.createdAt == "2026-01-01T00:00:00.000Z")
        #expect(comment.featureRequestId == "fr-1")
        #expect(comment.featureRequestTitle == "Title")
        #expect(comment.appId == "app-1")
        #expect(comment.appName == "App One")
    }
}

// MARK: - Client

@Suite("UserProfileClient", .serialized)
struct UserProfileClientTests {
    static let apiHost = "profiles.example.com"

    static func makeAPIClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(apiHost)")!)
    }

    @Test func fetchUserProfileHitsCorrectEndpoint() async throws {
        let capture = CaptureBox<URL>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request.url
            let body: [String: Any] = [
                "profile": ["clerkUserId": "user_123", "hideComments": false],
                "apps": [],
                "recentComments": [],
                "hideComments": false
            ]
            return (makeHTTPResponse(), try encodeJSON(body))
        }

        _ = try await Self.makeAPIClient().fetchUserProfile(userId: "user_123")

        let url = try #require(capture.value)
        #expect(url.path == "/api/v1/users/user_123/profile")
    }

    @Test func fetchUserProfileDecodesResponse() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            let body: [String: Any] = [
                "profile": ["clerkUserId": "user_123", "hideComments": false],
                "apps": [],
                "recentComments": [],
                "hideComments": false
            ]
            return (makeHTTPResponse(), try encodeJSON(body))
        }

        let response = try await Self.makeAPIClient().fetchUserProfile(userId: "user_123")
        #expect(response.profile.clerkUserId == "user_123")
    }

    @Test func fetchUserProfileThrowsOn404() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 404), try encodeJSON(["error": "User not found"]))
        }

        do {
            _ = try await Self.makeAPIClient().fetchUserProfile(userId: "user_unknown")
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            if case .unexpectedStatus(let code, _) = error {
                #expect(code == 404)
            } else {
                Issue.record("Unexpected error type: \\(error)")
            }
        }
    }
}
