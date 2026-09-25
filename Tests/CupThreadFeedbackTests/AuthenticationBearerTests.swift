import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Authenticated Bearer transport for allowAnonymous-gated endpoints (#156)

@Suite("AuthenticationBearer", .serialized)
struct AuthenticationBearerTests {
    static let apiHost = "authbearer.example.com"

    static func makeAPIClient(
        authenticationProvider: (@Sendable () async -> String?)? = nil
    ) -> FeedbackClient {
        makeClient(
            baseURL: URL(string: "https://\(apiHost)")!,
            authenticationProvider: authenticationProvider
        )
    }

    // MARK: - fetchComments

    @Test func fetchCommentsSendsBearerTokenFromAuthenticationProvider() async throws {
        let capture = CaptureBox<String?>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request.value(forHTTPHeaderField: "Authorization")
            return (makeHTTPResponse(), try encodeJSON(["comments": []]))
        }

        let client = Self.makeAPIClient(authenticationProvider: { "clerk-jwt-token" })
        #expect(client.supportsAuthentication)
        _ = try await client.fetchComments(featureRequestId: "fr-123")

        #expect(capture.value == "Bearer clerk-jwt-token")
    }

    @Test func fetchCommentsWithProviderReturningNilOmitsAuthorizationHeader() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["comments": []]))
        }

        let client = Self.makeAPIClient(authenticationProvider: { nil })
        _ = try await client.fetchComments(featureRequestId: "fr-123")

        let req = try #require(capture.value)
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func fetchCommentsWithoutProviderOmitsAuthorizationHeader() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["comments": []]))
        }

        let client = Self.makeAPIClient()
        #expect(client.supportsAuthentication == false)
        _ = try await client.fetchComments(featureRequestId: "fr-123")

        let req = try #require(capture.value)
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func fetchCommentsSucceedsWithBearerWhenAnonymousRoadmapIsDisabled() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer valid-clerk-token" {
                return (makeHTTPResponse(), try encodeJSON(["comments": []]))
            } else {
                return (
                    makeHTTPResponse(status: 401),
                    try encodeJSON([
                        "error": "Sign in is required to view comments",
                        "code": "authentication_required"
                    ])
                )
            }
        }

        let signedInClient = Self.makeAPIClient(authenticationProvider: { "valid-clerk-token" })
        let comments = try await signedInClient.fetchComments(featureRequestId: "fr-123")
        #expect(comments.isEmpty)

        let anonymousClient = Self.makeAPIClient()
        do {
            _ = try await anonymousClient.fetchComments(featureRequestId: "fr-123")
            Issue.record("Expected authenticationRequired for anonymous client")
        } catch let error as FeedbackClientError {
            #expect(error == .authenticationRequired)
        }
    }

    // MARK: - fetchFeatureRequests

    @Test func fetchFeatureRequestsSendsBearerTokenFromAuthenticationProvider() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["requests": [], "total": 0]))
        }

        let client = Self.makeAPIClient(authenticationProvider: { "clerk-jwt-token" })
        _ = try await client.fetchFeatureRequests(userToken: "tok-123")

        let req = try #require(capture.value)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer clerk-jwt-token")
        #expect(req.value(forHTTPHeaderField: "X-User-Token") == "tok-123")
    }

    @Test func fetchFeatureRequestsWithProviderReturningNilOmitsAuthorizationHeader() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["requests": [], "total": 0]))
        }

        let client = Self.makeAPIClient(authenticationProvider: { nil })
        _ = try await client.fetchFeatureRequests(userToken: "tok-123")

        let req = try #require(capture.value)
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(req.value(forHTTPHeaderField: "X-User-Token") == "tok-123")
    }

    @Test func fetchFeatureRequestsWithoutProviderOmitsAuthorizationHeader() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["requests": [], "total": 0]))
        }

        let client = Self.makeAPIClient()
        _ = try await client.fetchFeatureRequests(userToken: "tok-123")

        let req = try #require(capture.value)
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(req.value(forHTTPHeaderField: "X-User-Token") == "tok-123")
    }

    @Test func fetchFeatureRequestsSucceedsWithBearerWhenAnonymousRoadmapIsDisabled() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer valid-token" {
                return (makeHTTPResponse(), try encodeJSON(["requests": [], "total": 0]))
            } else {
                return (
                    makeHTTPResponse(status: 401),
                    try encodeJSON([
                        "error": "Authentication required",
                        "code": "authentication_required"
                    ])
                )
            }
        }

        let signedInClient = Self.makeAPIClient(authenticationProvider: { "valid-token" })
        let result = try await signedInClient.fetchFeatureRequests(userToken: "tok-123")
        #expect(result.requests.isEmpty)

        let anonymousClient = Self.makeAPIClient()
        do {
            _ = try await anonymousClient.fetchFeatureRequests(userToken: "tok-123")
            Issue.record("Expected authenticationRequired for anonymous client")
        } catch let error as FeedbackClientError {
            #expect(error == .authenticationRequired)
        }
    }

    // MARK: - fetchColumns

    @Test func fetchColumnsSendsBearerTokenFromAuthenticationProvider() async throws {
        let capture = CaptureBox<String?>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request.value(forHTTPHeaderField: "Authorization")
            return (makeHTTPResponse(), try encodeJSON(["columns": []]))
        }

        let client = Self.makeAPIClient(authenticationProvider: { "clerk-jwt-token" })
        _ = try await client.fetchColumns()

        #expect(capture.value == "Bearer clerk-jwt-token")
    }

    @Test func fetchColumnsWithProviderReturningNilOmitsAuthorizationHeader() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["columns": []]))
        }

        let client = Self.makeAPIClient(authenticationProvider: { nil })
        _ = try await client.fetchColumns()

        let req = try #require(capture.value)
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func fetchColumnsWithoutProviderOmitsAuthorizationHeader() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["columns": []]))
        }

        let client = Self.makeAPIClient()
        _ = try await client.fetchColumns()

        let req = try #require(capture.value)
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: - fetchVersions

    @Test func fetchVersionsSendsBearerTokenFromAuthenticationProvider() async throws {
        let capture = CaptureBox<String?>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request.value(forHTTPHeaderField: "Authorization")
            return (makeHTTPResponse(), try encodeJSON(["versions": []]))
        }

        let client = Self.makeAPIClient(authenticationProvider: { "clerk-jwt-token" })
        _ = try await client.fetchVersions()

        #expect(capture.value == "Bearer clerk-jwt-token")
    }

    @Test func fetchVersionsWithProviderReturningNilOmitsAuthorizationHeader() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["versions": []]))
        }

        let client = Self.makeAPIClient(authenticationProvider: { nil })
        _ = try await client.fetchVersions()

        let req = try #require(capture.value)
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func fetchVersionsWithoutProviderOmitsAuthorizationHeader() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["versions": []]))
        }

        let client = Self.makeAPIClient()
        _ = try await client.fetchVersions()

        let req = try #require(capture.value)
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: - fetchChangelog

    @Test func fetchChangelogSendsBearerTokenFromAuthenticationProvider() async throws {
        let capture = CaptureBox<String?>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request.value(forHTTPHeaderField: "Authorization")
            return (makeHTTPResponse(), try encodeJSON(["entries": []]))
        }

        let client = Self.makeAPIClient(authenticationProvider: { "clerk-jwt-token" })
        _ = try await client.fetchChangelog()

        #expect(capture.value == "Bearer clerk-jwt-token")
    }

    @Test func fetchChangelogWithProviderReturningNilOmitsAuthorizationHeader() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["entries": []]))
        }

        let client = Self.makeAPIClient(authenticationProvider: { nil })
        _ = try await client.fetchChangelog()

        let req = try #require(capture.value)
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func fetchChangelogWithoutProviderOmitsAuthorizationHeader() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["entries": []]))
        }

        let client = Self.makeAPIClient()
        _ = try await client.fetchChangelog()

        let req = try #require(capture.value)
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func fetchChangelogSucceedsWithBearerWhenAnonymousAccessIsDisabled() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer valid-token" {
                return (makeHTTPResponse(), try encodeJSON(["entries": []]))
            } else {
                return (makeHTTPResponse(status: 401), try encodeJSON(["code": "authentication_required"]))
            }
        }

        let signedInClient = Self.makeAPIClient(authenticationProvider: { "valid-token" })
        let entries = try await signedInClient.fetchChangelog()
        #expect(entries.isEmpty)

        let anonymousClient = Self.makeAPIClient()
        do {
            _ = try await anonymousClient.fetchChangelog()
            Issue.record("Expected authenticationRequired for anonymous client")
        } catch let error as FeedbackClientError {
            #expect(error == .authenticationRequired)
        }
    }

    // MARK: - subscribeToChangelog

    @Test func subscribeToChangelogSendsBearerTokenFromAuthenticationProvider() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(status: 201), try encodeJSON(["subscribed": true]))
        }

        let client = Self.makeAPIClient(authenticationProvider: { "clerk-jwt-token" })
        _ = try await client.subscribeToChangelog(
            email: "user@example.com",
            userToken: "tok-abc"
        )

        let req = try #require(capture.value)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer clerk-jwt-token")
        #expect(req.value(forHTTPHeaderField: "X-User-Token") == "tok-abc")
    }

    @Test func subscribeToChangelogWithProviderReturningNilOmitsAuthorizationHeader() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(status: 201), try encodeJSON(["subscribed": true]))
        }

        let client = Self.makeAPIClient(authenticationProvider: { nil })
        _ = try await client.subscribeToChangelog(
            email: "user@example.com",
            userToken: "tok-abc"
        )

        let req = try #require(capture.value)
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(req.value(forHTTPHeaderField: "X-User-Token") == "tok-abc")
    }

    @Test func subscribeToChangelogWithoutProviderOmitsAuthorizationHeader() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(status: 201), try encodeJSON(["subscribed": true]))
        }

        let client = Self.makeAPIClient()
        _ = try await client.subscribeToChangelog(
            email: "user@example.com",
            userToken: "tok-abc"
        )

        let req = try #require(capture.value)
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(req.value(forHTTPHeaderField: "X-User-Token") == "tok-abc")
    }
}
