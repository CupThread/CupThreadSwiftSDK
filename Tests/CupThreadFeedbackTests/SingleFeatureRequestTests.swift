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

    @Test func fetchFeatureRequestMapsJSONEnvelope404ToFeatureRequestNotFound() async throws {
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

    // Issue #406 (API-24): production's router-fallback 404 is text/plain
    // "404 Not Found" — the same answer any wrong baseURL or deploy skew
    // produces — so it must surface as `.unexpectedStatus(404)`, not as the
    // typed "this request does not exist" error hosts act on.
    @Test func fetchFeatureRequestMapsRouterFallback404ToUnexpectedStatus() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 404, headers: ["Content-Type": "text/plain"]),
                Data("404 Not Found".utf8)
            )
        }

        do {
            _ = try await Self.makeAPIClient().fetchFeatureRequest(id: "fr-42")
            Issue.record("Expected unexpectedStatus")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, let message, _) = error else {
                Issue.record("Expected .unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 404)
            #expect(message == "404 Not Found")
        }
    }

    @Test func fetchFeatureRequestMapsEmptyBody404ToUnexpectedStatus() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 404), Data())
        }

        do {
            _ = try await Self.makeAPIClient().fetchFeatureRequest(id: "fr-42")
            Issue.record("Expected unexpectedStatus")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, _, _) = error else {
                Issue.record("Expected .unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 404)
        }
    }

    @Test func fetchFeatureRequestMapsJSON404WithoutErrorFieldToUnexpectedStatus() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 404), try encodeJSON(["message": "not found"]))
        }

        do {
            _ = try await Self.makeAPIClient().fetchFeatureRequest(id: "fr-42")
            Issue.record("Expected unexpectedStatus")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, _, _) = error else {
                Issue.record("Expected .unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 404)
        }
    }

    // Issue #406 (API-24): deep-link ids are untrusted input. An id that
    // cannot be a single opaque path segment is rejected locally with the
    // documented not-found outcome and zero requests reach the session.
    @Test func fetchFeatureRequestRejectsHostileIdsLocallyWithoutNetwork() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(Self.makeSingleFeatureRequestJSON()))
        }

        let hostileIDs = [
            "abc/comments",
            "../vote",
            "a?b",
            "a#b",
            "a%2Fb",
            "a b",
            "",
            "   ",
            "über",
            "a\nb",
            String(repeating: "a", count: 129)
        ]
        for hostileID in hostileIDs {
            do {
                _ = try await Self.makeAPIClient().fetchFeatureRequest(id: hostileID)
                Issue.record("Expected featureRequestNotFound for id \(hostileID.debugDescription)")
            } catch let error as FeedbackClientError {
                guard case .featureRequestNotFound(let message, let requestId) = error else {
                    Issue.record("Expected .featureRequestNotFound for \(hostileID.debugDescription), got \(error)")
                    continue
                }
                #expect(message == nil)
                #expect(requestId == nil)
            }
        }
        #expect(capture.value == nil, "A hostile id must never reach the network")
    }

    @Test func fetchFeatureRequestAcceptsGrammarConformantIds() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(Self.makeSingleFeatureRequestJSON()))
        }

        let validIDs = [
            "fr-42",
            "f3dfa37f-3bdd-4b84-8dee-5e427081e456",
            "a_b",
            String(repeating: "a", count: 128)
        ]
        for validID in validIDs {
            let item = try await Self.makeAPIClient().fetchFeatureRequest(id: validID)
            #expect(item.id == "fr-42", "id \(validID.debugDescription) must reach the network")
        }
        let request = try #require(capture.value)
        #expect(request.url?.path == "/api/v1/feature-requests/\(validIDs.last!)")
    }

    // Issue #406 (API-24): a 200 body that does not decode must surface as
    // `.invalidResponse`, never as a raw DecodingError.
    @Test func fetchFeatureRequestMapsMalformedSuccessBodyToInvalidResponse() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(), try encodeJSON(["requests": []]))
        }

        do {
            _ = try await Self.makeAPIClient().fetchFeatureRequest(id: "fr-42")
            Issue.record("Expected invalidResponse")
        } catch let error as FeedbackClientError {
            guard case .invalidResponse = error else {
                Issue.record("Expected .invalidResponse, got \(error)")
                return
            }
        }
    }

    @Test func featureRequestIDGrammarBoundaries() {
        #expect(FeatureRequestIDGrammar.isValid("a"))
        #expect(FeatureRequestIDGrammar.isValid("fr-42_X"))
        #expect(FeatureRequestIDGrammar.isValid(String(repeating: "a", count: 128)))
        #expect(!FeatureRequestIDGrammar.isValid(""))
        #expect(!FeatureRequestIDGrammar.isValid("a/b"))
        #expect(!FeatureRequestIDGrammar.isValid("."))
        #expect(!FeatureRequestIDGrammar.isValid(".."))
        #expect(!FeatureRequestIDGrammar.isValid("a.b"))
        #expect(!FeatureRequestIDGrammar.isValid("a b"))
        #expect(!FeatureRequestIDGrammar.isValid("é"))
        #expect(!FeatureRequestIDGrammar.isValid(String(repeating: "a", count: 129)))
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
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), Data())
        }

        await #expect(throws: FeedbackClientError.featureRequestNotFound(message: nil, requestId: nil)) {
            _ = try await Self.makeAPIClient().fetchFeatureRequest(id: "   ")
        }
        #expect(capture.value == nil, "A blank id must be rejected before any request is sent")
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
