import Foundation
import Testing
@testable import CupThreadFeedback

@Suite("SingleFeatureRequest", .serialized)
struct SingleFeatureRequestTests {
    static let apiHost = "single-fr.example.com"

    static func makeAPIClient(
        authenticationProvider: (@Sendable () async -> String?)? = nil
    ) -> FeedbackClient {
        makeClient(
            baseURL: URL(string: "https://\(apiHost)")!,
            authenticationProvider: authenticationProvider
        )
    }

    private static func makeSingleFeatureRequestJSON(id: String = "fr-42") -> [String: Any] {
        [
            "request": [
                "id": id,
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
                "requesterAvatarUrl": "https://example.com/avatar.png",
                "requesterClerkId": "user_123",
                "recentCommenters": [[String: Any]](),
                "hasMoreCommenters": false,
                "approved": true,
                "voteCount": 7,
                "commentCount": 3,
                "hasVoted": true,
                "isOwnRequest": false,
                "createdAt": "2026-01-01T00:00:00.000Z",
                "updatedAt": "2026-02-01T00:00:00.000Z"
            ]
        ]
    }

    // MARK: - URL and Header Verification

    @Test func fetchFeatureRequestBuildsExpectedURLAndCorrelationHeaders() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (
                makeHTTPResponse(headers: ["X-Request-Id": "req-single-fr"]),
                try encodeJSON(Self.makeSingleFeatureRequestJSON())
            )
        }

        let item = try await Self.makeAPIClient().fetchFeatureRequest(id: "fr-42", userToken: "tok-single")

        let req = try #require(capture.value)
        #expect(req.url?.path == "/api/v1/feature-requests/fr-42")
        #expect(req.httpMethod == "GET")
        #expect(req.value(forHTTPHeaderField: "X-User-Token") == "tok-single")
        #expect(req.value(forHTTPHeaderField: "X-Request-Id") != nil)
        #expect(req.value(forHTTPHeaderField: "X-SDK-Version") != nil)
        #expect(item.id == "fr-42")
        #expect(item.title == "Dark mode")
        #expect(item.commentCount == 3)
    }

    @Test func fetchFeatureRequestOmitsUserTokenHeaderWhenNil() async throws {
        let capture = CaptureBox<String>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request.value(forHTTPHeaderField: "X-User-Token") ?? ""
            return (makeHTTPResponse(), try encodeJSON(Self.makeSingleFeatureRequestJSON()))
        }

        _ = try await Self.makeAPIClient().fetchFeatureRequest(id: "fr-42")

        #expect((capture.value ?? "").isEmpty)
    }

    // MARK: - Error Mapping

    @Test func fetchFeatureRequestMaps404ToFeatureRequestNotFound() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 404, headers: ["X-Request-Id": "req-fr-404"]),
                try encodeJSON(["error": "Feature request not found"])
            )
        }

        do {
            _ = try await Self.makeAPIClient().fetchFeatureRequest(id: "missing-fr")
            Issue.record("Expected featureRequestNotFound")
        } catch let error as FeedbackClientError {
            guard case .featureRequestNotFound(let message, let requestId) = error else {
                Issue.record("Expected .featureRequestNotFound, got \(error)")
                return
            }
            #expect(message == "Feature request not found")
            #expect(requestId == "req-fr-404")
        }
    }

    @Test func fetchFeatureRequestMaps401ToAuthenticationRequired() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 401, headers: ["X-Request-Id": "req-fr-401"]),
                try encodeJSON(["error": "Unauthorized", "code": "authentication_required"])
            )
        }

        await #expect(throws: FeedbackClientError.authenticationRequired) {
            _ = try await Self.makeAPIClient().fetchFeatureRequest(id: "fr-private")
        }
    }

    @Test func fetchFeatureRequestMaps403ToForbidden() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 403, headers: ["X-Request-Id": "req-fr-403"]),
                try encodeJSON(["error": "Roadmap is disabled"])
            )
        }

        do {
            _ = try await Self.makeAPIClient().fetchFeatureRequest(id: "fr-forbidden")
            Issue.record("Expected forbidden error")
        } catch let error as FeedbackClientError {
            guard case .forbidden(let message, let requestId) = error else {
                Issue.record("Expected .forbidden, got \(error)")
                return
            }
            #expect(message == "Roadmap is disabled")
            #expect(requestId == "req-fr-403")
        }
    }

    @Test func fetchFeatureRequestMaps429ToRateLimited() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 429, headers: ["X-Request-Id": "req-fr-429"]),
                try encodeJSON(["error": "Too many requests"])
            )
        }

        do {
            _ = try await Self.makeAPIClient().fetchFeatureRequest(id: "fr-42")
            Issue.record("Expected rateLimited")
        } catch let error as FeedbackClientError {
            guard case .rateLimited(let message, let requestId) = error else {
                Issue.record("Expected .rateLimited, got \(error)")
                return
            }
            #expect(message == "Too many requests")
            #expect(requestId == "req-fr-429")
        }
    }

    @Test func fetchFeatureRequestRejectsEmptyId() async throws {
        await #expect(throws: FeedbackClientError.invalidResponse) {
            _ = try await Self.makeAPIClient().fetchFeatureRequest(id: "   ")
        }
    }

    @Test func getFeatureRequestAliasCallsFetchFeatureRequest() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(), try encodeJSON(Self.makeSingleFeatureRequestJSON(id: "fr-alias")))
        }

        let item = try await Self.makeAPIClient().getFeatureRequest(id: "fr-alias", userToken: "tok-1")
        #expect(item.id == "fr-alias")
    }

    // MARK: - Bearer Token

    @Test func fetchFeatureRequestSendsBearerTokenFromAuthenticationProvider() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(Self.makeSingleFeatureRequestJSON()))
        }

        let client = Self.makeAPIClient(authenticationProvider: { "clerk-jwt-token" })
        _ = try await client.fetchFeatureRequest(id: "fr-123", userToken: "tok-123")

        let req = try #require(capture.value)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer clerk-jwt-token")
        #expect(req.value(forHTTPHeaderField: "X-User-Token") == "tok-123")
    }

    @Test func fetchFeatureRequestWithProviderReturningNilOmitsAuthorizationHeader() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(Self.makeSingleFeatureRequestJSON()))
        }

        let client = Self.makeAPIClient(authenticationProvider: { nil })
        _ = try await client.fetchFeatureRequest(id: "fr-123", userToken: "tok-123")

        let req = try #require(capture.value)
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(req.value(forHTTPHeaderField: "X-User-Token") == "tok-123")
    }

    @Test func fetchFeatureRequestWithoutProviderOmitsAuthorizationHeader() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(Self.makeSingleFeatureRequestJSON()))
        }

        let client = Self.makeAPIClient()
        _ = try await client.fetchFeatureRequest(id: "fr-123", userToken: "tok-123")

        let req = try #require(capture.value)
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(req.value(forHTTPHeaderField: "X-User-Token") == "tok-123")
    }
}
