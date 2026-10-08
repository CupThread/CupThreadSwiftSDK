import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - UserProfileClientTests

@Suite("UserProfileClient", .serialized)
struct UserProfileClientTests {
    static let apiHost = "profiles.example.com"

    static func makeAPIClient(
        authenticationProvider: (@Sendable () async -> String?)? = nil
    ) -> FeedbackClient {
        makeClient(
            baseURL: URL(string: "https://\(apiHost)")!,
            authenticationProvider: authenticationProvider
        )
    }

    @Test func fetchUserProfileHitsCorrectEndpoint() async throws {
        let capture = CaptureBox<URL>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request.url
            let body: [String: Any] = [
                "profile": ["clerkUserId": "user_123", "createdAt": "2026-01-01T00:00:00.000Z"],
                "publicApps": [],
                "recentComments": []
            ]
            return (makeHTTPResponse(), try encodeJSON(body))
        }

        _ = try await Self.makeAPIClient().fetchUserProfile(userId: "user_123")

        let url = try #require(capture.value)
        #expect(url.path == "/api/v1/users/user_123/profile")
    }

    @Test func fetchUserProfileSendsAppKeyForAppScopedPublicIds() async throws {
        // Board/comment payloads carry app-scoped public ids (`u_<32-hex>`),
        // which the server only resolves with an `appKey` query parameter
        // (#139); without it an existing user answers 404.
        let appScopedID = "u_" + String(repeating: "a", count: 32)
        let capture = CaptureBox<URL>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request.url
            let body: [String: Any] = [
                "profile": ["clerkUserId": appScopedID, "createdAt": "2026-01-01T00:00:00.000Z"],
                "publicApps": [],
                "recentComments": []
            ]
            return (makeHTTPResponse(), try encodeJSON(body))
        }

        _ = try await Self.makeAPIClient().fetchUserProfile(userId: appScopedID)

        let url = try #require(capture.value)
        #expect(url.path == "/api/v1/users/\(appScopedID)/profile")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = try #require(components.queryItems)
        #expect(queryItems.count == 1)
        #expect(queryItems.first?.name == "appKey")
        #expect(queryItems.first?.value == "app_testkey123456")
    }

    @Test func fetchUserProfileOmitsAppKeyForRawClerkIds() async throws {
        // Raw Clerk ids (`user_*`) keep working for existing /u/ bookmarks
        // without the app-scoped lookup parameter.
        let capture = CaptureBox<URL>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request.url
            let body: [String: Any] = [
                "profile": ["clerkUserId": "user_bookmark", "createdAt": "2026-01-01T00:00:00.000Z"],
                "publicApps": [],
                "recentComments": []
            ]
            return (makeHTTPResponse(), try encodeJSON(body))
        }

        _ = try await Self.makeAPIClient().fetchUserProfile(userId: "user_bookmark")

        let url = try #require(capture.value)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.contains { $0.name == "appKey" } != true)
    }

    @Test func fetchUserProfileThrowsRateLimitedOn429() async throws {
        // Per-client-IP rate limiting (September 2026 API sync, #139) maps to
        // the shared typed 429 error with friendly copy, like other public
        // metered endpoints.
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 429, headers: ["X-Request-Id": "req-429-profile"]),
                try encodeJSON(["error": "Too many requests. Please try again shortly."])
            )
        }

        do {
            _ = try await Self.makeAPIClient().fetchUserProfile(userId: "user_ratelimited")
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            if case .rateLimited(let message, let requestId) = error {
                #expect(message == "Too many requests. Please try again shortly.")
                #expect(requestId == "req-429-profile")
                #expect(
                    error.errorDescription
                        == CupThreadStrings.tr("cupthread.error.http_rate_limited") + " (request id: req-429-profile)"
                )
                #expect(error.responseBody == nil)
            } else {
                Issue.record("Unexpected error type: \(error)")
            }
        }
    }

    @Test func fetchUserProfileDecodesAuthoritativeResponse() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            let body: [String: Any] = [
                "profile": [
                    "clerkUserId": "user_authoritative",
                    "displayName": "Alex",
                    "avatarUrl": "https://example.com/avatar.png",
                    "bio": "Engineer",
                    "websiteUrl": "https://example.com",
                    "createdAt": "2026-01-01T00:00:00.000Z"
                ],
                "publicApps": [
                    [
                        "id": "app-1",
                        "workspaceSlug": "ws-alpha",
                        "workspaceName": "Alpha",
                        "appSlug": "alpha-app",
                        "name": "Alpha App",
                        "description": "Description"
                    ]
                ],
                "recentComments": [
                    [
                        "id": "c-10",
                        "body": "Nice work!",
                        "createdAt": "2026-01-01T00:00:00.000Z",
                        "featureRequestId": "fr-10",
                        "featureRequestTitle": "Feature 10",
                        "workspaceSlug": "ws-alpha",
                        "appSlug": "alpha-app",
                        "appName": "Alpha App"
                    ]
                ]
            ]
            return (makeHTTPResponse(), try encodeJSON(body))
        }

        let response = try await Self.makeAPIClient().fetchUserProfile(userId: "user_authoritative")
        #expect(response.profile.clerkUserId == "user_authoritative")
        #expect(response.apps.count == 1)
        #expect(response.apps[0].slug == "alpha-app")
        #expect(response.apps[0].workspaceSlug == "ws-alpha")
        #expect(response.recentComments.count == 1)
        #expect(response.recentComments[0].appId == nil)
        #expect(response.recentComments[0].workspaceSlug == "ws-alpha")
    }

    @Test func fetchUserProfileThrowsUserProfileNotFoundOn404() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 404), try encodeJSON(["error": "User profile not found"]))
        }

        do {
            _ = try await Self.makeAPIClient().fetchUserProfile(userId: "user_unknown")
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            if case .userProfileNotFound(let message) = error {
                // The server text stays on the case for diagnostics (#30);
                // the displayed copy is the friendly fallback.
                #expect(message == "User profile not found")
                #expect(error.responseBody == "User profile not found")
                #expect(error.errorDescription == CupThreadStrings.tr("cupthread.error.profile_not_found"))
            } else {
                Issue.record("Unexpected error type: \(error)")
            }
        }
    }

    @Test func fetchUserProfileThrowsUserProfileNotFoundWithDefaultMessageOnEmpty404() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 404), Data())
        }

        do {
            _ = try await Self.makeAPIClient().fetchUserProfile(userId: "user_empty_404")
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            if case .userProfileNotFound(let message) = error {
                #expect(message == nil)
                #expect(error.errorDescription == CupThreadStrings.tr("cupthread.error.profile_not_found"))
            } else {
                Issue.record("Unexpected error type: \(error)")
            }
        }
    }

    @Test func fetchUserProfileThrowsUnexpectedStatusOn500WithoutCrashing() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 500), try encodeJSON(["error": "Internal server error"]))
        }

        do {
            _ = try await Self.makeAPIClient().fetchUserProfile(userId: "user_500")
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            if case .unexpectedStatus(let code, let message, _) = error {
                #expect(code == 500)
                #expect(message == "Internal server error")
            } else {
                Issue.record("Unexpected error type: \(error)")
            }
        }
    }

    @Test func fetchUserProfileAttachesBearerTokenWhenAuthenticated() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            let body: [String: Any] = [
                "profile": ["clerkUserId": "user_123", "createdAt": "2026-01-01T00:00:00.000Z"],
                "publicApps": [],
                "recentComments": []
            ]
            return (makeHTTPResponse(), try encodeJSON(body))
        }

        let client = Self.makeAPIClient(authenticationProvider: { "token-123" })
        _ = try await client.fetchUserProfile(userId: "user_123")

        let request = try #require(capture.value)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-123")
        #expect(request.value(forHTTPHeaderField: "X-Request-Id") != nil)
        #expect(request.value(forHTTPHeaderField: "X-SDK-Version") != nil)
    }

    @Test func fetchUserProfileOmitsAuthorizationWhenProviderReturnsNil() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            let body: [String: Any] = [
                "profile": ["clerkUserId": "user_123", "createdAt": "2026-01-01T00:00:00.000Z"],
                "publicApps": [],
                "recentComments": []
            ]
            return (makeHTTPResponse(), try encodeJSON(body))
        }

        let client = Self.makeAPIClient(authenticationProvider: { nil })
        _ = try await client.fetchUserProfile(userId: "user_123")

        let request = try #require(capture.value)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func fetchUserProfileOmitsAuthorizationWithoutProvider() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            let body: [String: Any] = [
                "profile": ["clerkUserId": "user_123", "createdAt": "2026-01-01T00:00:00.000Z"],
                "publicApps": [],
                "recentComments": []
            ]
            return (makeHTTPResponse(), try encodeJSON(body))
        }

        let client = Self.makeAPIClient()
        _ = try await client.fetchUserProfile(userId: "user_123")

        let request = try #require(capture.value)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func fetchUserProfileMapsCodeless403ToForbidden() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 403, headers: ["X-Request-Id": "req-403-profile"]),
                try encodeJSON(["error": "Forbidden permission policy"])
            )
        }

        do {
            _ = try await Self.makeAPIClient().fetchUserProfile(userId: "user_forbidden")
            Issue.record("Expected forbidden error to be thrown")
        } catch let error as FeedbackClientError {
            if case .forbidden(let message, let requestId) = error {
                #expect(message == "Forbidden permission policy")
                #expect(requestId == "req-403-profile")
            } else {
                Issue.record("Unexpected error type: \(error)")
            }
        }
    }

    @Test func fetchUserProfileMapsCodeless401ToAuthenticationRequired() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 401, headers: ["X-Request-Id": "req-401-profile"]),
                try encodeJSON(["error": "Sign in required"])
            )
        }

        do {
            _ = try await Self.makeAPIClient().fetchUserProfile(userId: "user_unauthed")
            Issue.record("Expected authenticationRequired error to be thrown")
        } catch let error as FeedbackClientError {
            #expect(error == .authenticationRequired)
        }
    }

    @Test func fetchUserProfileMapsAuthenticationRequiredEnvelopeToTypedError() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 401, headers: ["X-Request-Id": "req-401-profile"]),
                try encodeJSON([
                    "error": "Sign in required",
                    "code": "authentication_required"
                ])
            )
        }

        do {
            _ = try await Self.makeAPIClient().fetchUserProfile(userId: "user_unauthed")
            Issue.record("Expected authenticationRequired error to be thrown")
        } catch let error as FeedbackClientError {
            #expect(error == .authenticationRequired)
        }
    }
}
