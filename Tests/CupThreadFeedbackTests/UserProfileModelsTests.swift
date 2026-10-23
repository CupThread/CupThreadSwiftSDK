import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - User profile model decoding and normalization tests

@Suite("UserProfileModels")
struct UserProfileModelsTests {
    @Test func userProfileDecodesCorrectedShapeAndIgnoresRetiredFields() throws {
        // `hideComments` and `updatedAt` are not part of the corrected
        // `UserProfile` component (#505); a payload that still carries them
        // must not resurrect them.
        let json = Data("""
        {
            "clerkUserId": "user_123",
            "displayName": "Lex",
            "avatarUrl": "https://example.com/avatar.png",
            "bio": "Developer",
            "websiteUrl": "https://example.com",
            "hideComments": true,
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
        #expect(profile.createdAt == "2026-01-01T00:00:00.000Z")
        #expect(profile.hideComments == false)
        #expect(profile.updatedAt == nil)
    }

    @Test func userProfileRequiresTheSixDocumentedKeys() {
        // The corrected `UserProfile` component marks all six keys
        // required; an absent key is contract drift (issue #505).
        let json = Data("""
        {
            "clerkUserId": "user_456"
        }
        """.utf8)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(UserProfile.self, from: json)
        }
    }

    @Test func userProfileAcceptsNullForNullableKeys() throws {
        let json = Data("""
        {
            "clerkUserId": "user_456",
            "displayName": null,
            "avatarUrl": null,
            "bio": null,
            "websiteUrl": null,
            "createdAt": "2026-01-01T00:00:00.000Z"
        }
        """.utf8)

        let profile = try JSONDecoder().decode(UserProfile.self, from: json)
        #expect(profile.clerkUserId == "user_456")
        #expect(profile.displayName == nil)
        #expect(profile.avatarUrl == nil)
        #expect(profile.bio == nil)
        #expect(profile.websiteUrl == nil)
        #expect(profile.createdAt == "2026-01-01T00:00:00.000Z")
    }

    @Test func userProfileRefusesToEncodeWithoutCreatedAt() {
        // Encoding a profile with no timestamp would emit JSON null, which
        // the corrected decoder rejects; fail at encode instead (issue #505).
        let profile = UserProfile(clerkUserId: "user_789")

        #expect(throws: EncodingError.self) {
            _ = try JSONEncoder().encode(profile)
        }
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

        #expect(response.publicApps.count == 1)
        #expect(response.apps == response.publicApps)
        let app = response.publicApps[0]
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

    @Test func publicUserProfileResponseRejectsThePhantomAppsKey() {
        // The server has always served `publicApps`; the documented `apps`
        // key was the spec defect this issue corrected (#505). A payload
        // that still uses it must fail loudly instead of rendering an empty
        // profile.
        let json = Data("""
        {
            "profile": {
                "clerkUserId": "user_2",
                "displayName": null,
                "avatarUrl": null,
                "bio": null,
                "websiteUrl": null,
                "createdAt": "2026-01-01T00:00:00.000Z",
                "hideComments": true
            },
            "apps": [],
            "recentComments": [],
            "hideComments": true
        }
        """.utf8)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(PublicUserProfileResponse.self, from: json)
        }
    }

    @Test func publicUserProfileResponseRequiresRecentComments() {
        // `recentComments` is always emitted, even when the user hides
        // comments; treating it as optional hides contract drift (#505).
        let json = Data("""
        {
            "profile": {
                "clerkUserId": "user_2",
                "displayName": null,
                "avatarUrl": null,
                "bio": null,
                "websiteUrl": null,
                "createdAt": "2026-01-01T00:00:00.000Z"
            },
            "publicApps": []
        }
        """.utf8)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(PublicUserProfileResponse.self, from: json)
        }
    }

    @Test func publicUserProfileResponseEncodesOnlyTheCorrectedKeys() throws {
        let profile = UserProfile(
            clerkUserId: "u1",
            displayName: "Alice",
            avatarUrl: nil,
            bio: nil,
            websiteUrl: nil,
            hideComments: false,
            createdAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-01-02T00:00:00.000Z"
        )
        let app = PublicAppSummary(
            id: "app1",
            name: "Demo",
            slug: "demo"
        )
        let comment = UserProfileComment(
            id: "c1",
            body: "Hello",
            createdAt: "2026-01-01T00:00:00.000Z",
            featureRequestId: "fr1",
            featureRequestTitle: "Feature",
            appId: "retired-app-id",
            appName: "Demo",
            workspaceSlug: "ws",
            appSlug: "demo"
        )
        let response = PublicUserProfileResponse(
            profile: profile,
            apps: [app],
            recentComments: [comment],
            hideComments: true
        )

        let data = try JSONEncoder().encode(response)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let encodedProfile = json?["profile"] as? [String: Any]
        let encodedComments = json?["recentComments"] as? [[String: Any]]
        let encodedApps = json?["publicApps"] as? [[String: Any]]

        #expect(json?["publicApps"] != nil)
        #expect(json?["apps"] == nil, "Legacy fallback key 'apps' should not be encoded")
        #expect(json?["hideComments"] == nil, "Retired top-level hideComments should not be encoded")
        #expect(encodedProfile?["hideComments"] == nil)
        #expect(encodedProfile?["updatedAt"] == nil)
        #expect(encodedComments?.first?["appId"] == nil)
        #expect(encodedApps?.first?["slug"] == nil, "The phantom 'slug' key should not be encoded")
        #expect(encodedApps?.first?["requestCount"] == nil)

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
            "workspaceName": "Workspace Three",
            "description": null,
            "iconUrl": null
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

    @Test func publicAppSummaryRequiresAppSlug() {
        // The profile endpoint has always served `appSlug`; the documented
        // `slug` name belonged to the showcase item, not this component.
        let json = Data("""
        {
            "id": "app-4",
            "name": "App Four",
            "slug": "app-four",
            "workspaceSlug": "ws-4",
            "workspaceName": "Workspace Four",
            "description": null,
            "iconUrl": null
        }
        """.utf8)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(PublicAppSummary.self, from: json)
        }
    }

    @Test func publicAppSummaryRequiresEveryComponentKey() {
        // All seven `PublicUserProfileApp` keys are required; the nullable
        // ones may be null but must be present (issue #505).
        let json = Data("""
        {
            "id": "app-5",
            "name": "App Five",
            "appSlug": "app-five",
            "workspaceSlug": "ws-5",
            "workspaceName": "Workspace Five"
        }
        """.utf8)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(PublicAppSummary.self, from: json)
        }
    }

    @Test func userProfileCommentRequiresWorkspaceAndAppSlugs() {
        let json = Data("""
        {
            "id": "c-3",
            "body": "Missing scoping slugs",
            "createdAt": "2026-01-02T00:00:00.000Z",
            "featureRequestId": "fr-3",
            "featureRequestTitle": "FR 3",
            "appName": "App Three"
        }
        """.utf8)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(UserProfileComment.self, from: json)
        }
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

    @Test func userProfileCommentRefusesToEncodeWithoutSlugs() {
        // Encoding without either required slug would omit a key the
        // corrected decoder requires; fail at encode instead (issue #505).
        let comment = UserProfileComment(
            id: "c-4",
            body: "Missing slugs",
            createdAt: "2026-01-02T00:00:00.000Z",
            featureRequestId: "fr-4",
            featureRequestTitle: "FR 4",
            appName: "App Four"
        )

        #expect(throws: EncodingError.self) {
            _ = try JSONEncoder().encode(comment)
        }
    }
}
