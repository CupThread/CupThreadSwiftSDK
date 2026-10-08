import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - User profile model decoding and normalization tests

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
            "clerkUserId": "user_456"
        }
        """.utf8)

        let profile = try JSONDecoder().decode(UserProfile.self, from: json)
        #expect(profile.clerkUserId == "user_456")
        #expect(profile.displayName == nil)
        #expect(profile.avatarUrl == nil)
        #expect(profile.bio == nil)
        #expect(profile.websiteUrl == nil)
        #expect(profile.hideComments == false)
        #expect(profile.createdAt == nil)
        #expect(profile.updatedAt == nil)
    }

    @Test func userProfileDecodesFromAuthoritativeBackendShapeWithoutHideCommentsAndUpdatedAt() throws {
        let json = Data("""
        {
            "clerkUserId": "user_789",
            "displayName": "Backend User",
            "avatarUrl": "https://example.com/avatar.png",
            "bio": "Real backend profile",
            "websiteUrl": "https://example.com",
            "createdAt": "2026-01-01T00:00:00.000Z"
        }
        """.utf8)

        let profile = try JSONDecoder().decode(UserProfile.self, from: json)
        #expect(profile.clerkUserId == "user_789")
        #expect(profile.displayName == "Backend User")
        #expect(profile.hideComments == false)
        #expect(profile.updatedAt == nil)
    }

    @Test func userProfileWebsiteUrlNormalizesSafely() throws {
        // Bare domain becomes https://
        #expect(normalizeWebsiteURL("example.com") == URL(string: "https://example.com"))
        // Existing https is preserved
        #expect(normalizeWebsiteURL("https://example.com") == URL(string: "https://example.com"))
        // Disallowed schemes are rejected (not tappable)
        #expect(normalizeWebsiteURL("tel:1234567890") == nil)
        #expect(normalizeWebsiteURL("javascript:alert(1)") == nil)
        #expect(normalizeWebsiteURL("shortcuts://run") == nil)
        #expect(normalizeWebsiteURL("myapp://open") == nil)
    }

    @Test func publicUserProfileResponseDecodesAuthoritativeBackendShape() throws {
        let json = Data("""
        {
            "profile": {
                "clerkUserId": "user_1",
                "displayName": "Developer",
                "avatarUrl": "https://example.com/icon.png",
                "bio": "Bio",
                "websiteUrl": "https://example.com",
                "createdAt": "2026-01-01T00:00:00.000Z"
            },
            "publicApps": [
                {
                    "id": "app-1",
                    "workspaceSlug": "ws-1",
                    "workspaceName": "Workspace One",
                    "appSlug": "app-one",
                    "name": "App One",
                    "description": "An app",
                    "iconUrl": "https://example.com/app.png"
                }
            ],
            "recentComments": [
                {
                    "id": "c-1",
                    "body": "Great feature!",
                    "createdAt": "2026-01-01T00:00:00.000Z",
                    "featureRequestId": "fr-1",
                    "featureRequestTitle": "FR Title",
                    "workspaceSlug": "ws-1",
                    "appSlug": "app-one",
                    "appName": "App One"
                }
            ]
        }
        """.utf8)

        let response = try JSONDecoder().decode(PublicUserProfileResponse.self, from: json)
        #expect(response.profile.clerkUserId == "user_1")
        #expect(response.profile.hideComments == false)
        #expect(response.hideComments == false)

        #expect(response.apps.count == 1)
        #expect(response.publicApps.count == 1)
        let app = response.apps[0]
        #expect(app.id == "app-1")
        #expect(app.slug == "app-one")
        #expect(app.appSlug == "app-one")
        #expect(app.workspaceSlug == "ws-1")
        #expect(app.workspaceName == "Workspace One")
        #expect(app.requestCount == nil)

        #expect(response.recentComments.count == 1)
        let comment = response.recentComments[0]
        #expect(comment.id == "c-1")
        #expect(comment.appId == nil)
        #expect(comment.workspaceSlug == "ws-1")
        #expect(comment.appSlug == "app-one")
        #expect(comment.appName == "App One")
    }

    @Test func publicUserProfileResponseDecodesLegacyShape() throws {
        let json = Data("""
        {
            "profile": {
                "clerkUserId": "user_2",
                "hideComments": true
            },
            "apps": [
                {
                    "id": "app-2",
                    "name": "App Two",
                    "slug": "app-two",
                    "requestCount": 12
                }
            ],
            "recentComments": [],
            "hideComments": true
        }
        """.utf8)

        let response = try JSONDecoder().decode(PublicUserProfileResponse.self, from: json)
        #expect(response.profile.clerkUserId == "user_2")
        #expect(response.apps.count == 1)
        #expect(response.apps[0].slug == "app-two")
        #expect(response.apps[0].requestCount == 12)
        #expect(response.hideComments == true)
    }

    @Test func publicUserProfileResponseEncodesCanonicalKeyWithoutDuplicateApps() throws {
        let profile = UserProfile(
            clerkUserId: "u1",
            displayName: "Alice",
            avatarUrl: nil,
            bio: nil,
            websiteUrl: nil,
            hideComments: false
        )
        let app = PublicAppSummary(
            id: "app1",
            name: "Demo",
            slug: "demo"
        )
        let response = PublicUserProfileResponse(
            profile: profile,
            apps: [app],
            recentComments: [],
            hideComments: false
        )

        let data = try JSONEncoder().encode(response)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["publicApps"] != nil)
        #expect(json?["apps"] == nil, "Legacy fallback key 'apps' should not be redundantly encoded")

        let decoded = try JSONDecoder().decode(PublicUserProfileResponse.self, from: data)
        #expect(decoded == response)
    }

    @Test func publicAppSummaryDecodesWithAppSlug() throws {
        let json = Data("""
        {
            "id": "app-3",
            "name": "App Three",
            "appSlug": "app-three",
            "workspaceSlug": "ws-3",
            "workspaceName": "Workspace Three"
        }
        """.utf8)

        let app = try JSONDecoder().decode(PublicAppSummary.self, from: json)
        #expect(app.id == "app-3")
        #expect(app.name == "App Three")
        #expect(app.slug == "app-three")
        #expect(app.appSlug == "app-three")
        #expect(app.workspaceSlug == "ws-3")
        #expect(app.workspaceName == "Workspace Three")
        #expect(app.requestCount == nil)
    }

    @Test func userProfileCommentDecodesWithoutAppId() throws {
        let json = Data("""
        {
            "id": "c-2",
            "body": "Another comment",
            "createdAt": "2026-01-02T00:00:00.000Z",
            "featureRequestId": "fr-2",
            "featureRequestTitle": "FR 2",
            "appName": "App Two",
            "workspaceSlug": "ws-2",
            "appSlug": "app-two"
        }
        """.utf8)

        let comment = try JSONDecoder().decode(UserProfileComment.self, from: json)
        #expect(comment.id == "c-2")
        #expect(comment.appId == nil)
        #expect(comment.workspaceSlug == "ws-2")
        #expect(comment.appSlug == "app-two")
        #expect(comment.appName == "App Two")
    }
}
