import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - SEC-25: FeedbackClient Bearer Token Security Tests (#433)

@Suite("FeedbackClient Bearer Token Security Tests", .serialized)
struct FeedbackClientBearerTokenSecurityTests {
    static let apiHost = "bearertoken-sec-test.example.com"

    static func makeSecurityClient(
        authenticationProvider: (@Sendable () async -> String?)? = nil
    ) -> FeedbackClient {
        makeClient(
            baseURL: URL(string: "https://\(apiHost)")!,
            authenticationProvider: authenticationProvider
        )
    }

    // MARK: - applyBearerToken Unit Tests

    @Test(
        "applyBearerToken ignores tokens with embedded newlines to prevent header injection",
        arguments: [
            "valid_token\r\nX-Injected-Header: injected_value",
            "token\ninjected",
            "token\rinjected",
            "token\r\ninjected",
            "token\u{2028}injected",
            "token\u{2029}injected",
            "token\u{0085}injected"
        ]
    )
    func testRejectsBearerTokenWithEmbeddedNewlines(maliciousToken: String) async {
        let client = Self.makeSecurityClient(authenticationProvider: { maliciousToken })

        var request = URLRequest(url: URL(string: "https://\(Self.apiHost)/api/v1/feature-requests")!)
        await client.applyBearerToken(to: &request)

        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Injected-Header") == nil)
    }

    @Test("applyBearerToken attaches valid single-line tokens normally")
    func testAttachesValidBearerToken() async {
        let validToken = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.e30.t-IDcSemACt8x4iTMCda8Yhe3iZaWbvV5XKSTbuAn0M"
        let client = Self.makeSecurityClient(authenticationProvider: { validToken })

        var request = URLRequest(url: URL(string: "https://\(Self.apiHost)/api/v1/feature-requests")!)
        await client.applyBearerToken(to: &request)

        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(validToken)")
    }

    @Test("applyBearerToken trims surrounding whitespace from valid tokens")
    func testTrimsSurroundingWhitespaceFromValidToken() async {
        let client = Self.makeSecurityClient(authenticationProvider: { "   valid_bearer_token   " })

        var request = URLRequest(url: URL(string: "https://\(Self.apiHost)/api/v1/feature-requests")!)
        await client.applyBearerToken(to: &request)

        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer valid_bearer_token")
    }

    @Test("applyBearerToken omits header for nil, empty, and whitespace-only tokens")
    func testApplyBearerTokenOmitsHeaderForEmptyOrWhitespaceOnly() async {
        let emptyCases: [String?] = [nil, "", "   ", "\r\n", " \n \r "]
        for candidate in emptyCases {
            let client = Self.makeSecurityClient(authenticationProvider: { candidate })
            var request = URLRequest(url: URL(string: "https://\(Self.apiHost)/api/v1/feature-requests")!)
            await client.applyBearerToken(to: &request)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        }
    }

    @Test("applyBearerToken leaves request unchanged when no provider is installed")
    func testApplyBearerTokenWithoutProviderLeavesRequestUnchanged() async {
        let client = Self.makeSecurityClient()

        var request = URLRequest(url: URL(string: "https://\(Self.apiHost)/api/v1/feature-requests")!)
        await client.applyBearerToken(to: &request)

        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: - resolveAuthenticatedAccess Unit Tests

    @Test(
        "resolveAuthenticatedAccess returns false when token contains newlines",
        arguments: [
            "token\ninjected",
            "token\rinjected",
            "token\r\ninjected",
            "token\r\nX-Injected: value",
            "token\u{2028}injected",
            "token\u{2029}injected",
            "token\u{0085}injected"
        ]
    )
    func testResolveAuthenticatedAccessReturnsFalseOnNewlines(maliciousToken: String) async {
        let client = Self.makeSecurityClient(authenticationProvider: { maliciousToken })
        #expect(await client.resolveAuthenticatedAccess() == false)
    }

    @Test("resolveAuthenticatedAccess returns true for valid single-line token")
    func testResolveAuthenticatedAccessReturnsTrueForValidToken() async {
        let client = Self.makeSecurityClient(authenticationProvider: { "valid_jwt_token_123" })
        #expect(await client.resolveAuthenticatedAccess() == true)
    }

    @Test("resolveAuthenticatedAccess returns false when provider returns nil or blank")
    func testResolveAuthenticatedAccessReturnsFalseWhenProviderReturnsNilOrBlank() async {
        #expect(await Self.makeSecurityClient(authenticationProvider: { nil }).resolveAuthenticatedAccess() == false)
        #expect(await Self.makeSecurityClient(authenticationProvider: { "" }).resolveAuthenticatedAccess() == false)
        #expect(await Self.makeSecurityClient(authenticationProvider: { "   " }).resolveAuthenticatedAccess() == false)
        #expect(await Self.makeSecurityClient().resolveAuthenticatedAccess() == false)
    }

    // MARK: - Wire Level Integration Tests

    @Test("Wire level: fetchComments omits Authorization header when bearer contains newlines")
    func testWireLevelFetchCommentsOmitsHeaderOnNewline() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["comments": []]))
        }

        let malicious = "evil_token\r\nX-Injected: attack"
        let client = Self.makeSecurityClient(authenticationProvider: { malicious })
        _ = try await client.fetchComments(featureRequestId: "fr-123")

        let req = try #require(capture.value)
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(req.value(forHTTPHeaderField: "X-Injected") == nil)
    }

    @Test("Wire level: fetchFeatureRequests omits Authorization header when bearer contains newlines")
    func testWireLevelFetchFeatureRequestsOmitsHeaderOnNewline() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["requests": [], "total": 0]))
        }

        let malicious = "token\r\nAuthorization: Injected"
        let client = Self.makeSecurityClient(authenticationProvider: { malicious })
        _ = try await client.fetchFeatureRequests(userToken: "tok-123")

        let req = try #require(capture.value)
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Wire level: createUploadSession omits Authorization header when bearer contains newlines")
    func testWireLevelCreateUploadSessionOmitsHeaderOnNewline() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (
                makeHTTPResponse(status: 201),
                try encodeJSON([
                    "session": [
                        "sessionId": "sess_123",
                        "sessionToken": "stok_123",
                        "expiresAt": "2030-01-01T00:00:00Z"
                    ],
                    "files": [
                        [
                            "uploadId": "upl_1",
                            "key": "attachments/upl_1.png",
                            "uploadUrl": "https://\(Self.apiHost)/api/v1/uploads/upl_1"
                        ]
                    ]
                ])
            )
        }

        let malicious = "malicious_token\r\nInjected: true"
        let client = Self.makeSecurityClient(authenticationProvider: { malicious })
        _ = try await client.createUploadSession(
            files: [FeedbackUploadFileSpec(clientFileId: "f1", filename: "shot.png", contentType: "image/png", sizeBytes: 1024)],
            userToken: "tok-123"
        )

        let req = try #require(capture.value)
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(req.value(forHTTPHeaderField: "Injected") == nil)
    }

    @Test("Wire level: endpoints attach Authorization header for valid single-line bearer tokens")
    func testWireLevelEndpointsAttachValidBearerHeader() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["comments": []]))
        }

        let validToken = "valid_secure_token_123"
        let client = Self.makeSecurityClient(authenticationProvider: { validToken })
        _ = try await client.fetchComments(featureRequestId: "fr-123")

        let req = try #require(capture.value)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer \(validToken)")
    }
}
