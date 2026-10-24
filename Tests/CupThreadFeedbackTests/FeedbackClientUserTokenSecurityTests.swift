import Foundation
import Testing
@testable import CupThreadFeedback

@Suite("FeedbackClient User Token Security Tests", .serialized)
struct FeedbackClientUserTokenSecurityTests {

    @Test(
        "applyUserToken rejects tokens with embedded newlines to prevent header injection",
        arguments: [
            "valid_token\r\nX-Injected-Header: injected_value",
            "malicious\ntoken",
            "malicious\rtoken",
            "malicious\r\ntoken",
            "token\r\nX-Injected: value",
            "tok\u{0085}en",
            "tok\u{2028}en",
            "tok\u{2029}en"
        ]
    )
    func testRejectsUserTokenWithEmbeddedNewlines(maliciousToken: String) {
        let configuration = FeedbackClientConfiguration(
            baseURL: URL(string: "https://api.cupthread.com")!,
            appKey: "app_test_key"
        )
        let client = FeedbackClient(configuration: configuration)
        var request = URLRequest(url: URL(string: "https://api.cupthread.com/api/v1/feature-requests")!)
        client.applyUserToken(maliciousToken, to: &request)

        #expect(request.value(forHTTPHeaderField: "X-User-Token") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Injected-Header") == nil)
    }

    @Test("applyUserToken attaches valid single-line user tokens")
    func testAttachesValidUserToken() {
        let configuration = FeedbackClientConfiguration(
            baseURL: URL(string: "https://api.cupthread.com")!,
            appKey: "app_test_key"
        )
        let client = FeedbackClient(configuration: configuration)
        let validToken = "usr_12345678-1234-1234-1234-123456789abc"

        var request = URLRequest(url: URL(string: "https://api.cupthread.com/api/v1/feature-requests")!)
        client.applyUserToken(validToken, to: &request)

        #expect(request.value(forHTTPHeaderField: "X-User-Token") == validToken)
    }

    @Test("applyUserToken omits header for nil, empty, and whitespace-only tokens")
    func testApplyUserTokenOmitsHeaderForEmptyOrWhitespaceOnly() {
        let configuration = FeedbackClientConfiguration(
            baseURL: URL(string: "https://api.cupthread.com")!,
            appKey: "app_test_key"
        )
        let client = FeedbackClient(configuration: configuration)

        var request1 = URLRequest(url: URL(string: "https://api.cupthread.com/api/v1/feature-requests")!)
        client.applyUserToken(nil, to: &request1)
        #expect(request1.value(forHTTPHeaderField: "X-User-Token") == nil)

        var request2 = URLRequest(url: URL(string: "https://api.cupthread.com/api/v1/feature-requests")!)
        client.applyUserToken("", to: &request2)
        #expect(request2.value(forHTTPHeaderField: "X-User-Token") == nil)

        var request3 = URLRequest(url: URL(string: "https://api.cupthread.com/api/v1/feature-requests")!)
        client.applyUserToken("   ", to: &request3)
        #expect(request3.value(forHTTPHeaderField: "X-User-Token") == nil)

        var request4 = URLRequest(url: URL(string: "https://api.cupthread.com/api/v1/feature-requests")!)
        client.applyUserToken("\r\n", to: &request4)
        #expect(request4.value(forHTTPHeaderField: "X-User-Token") == nil)

        var request5 = URLRequest(url: URL(string: "https://api.cupthread.com/api/v1/feature-requests")!)
        client.applyUserToken(" \n \r ", to: &request5)
        #expect(request5.value(forHTTPHeaderField: "X-User-Token") == nil)
    }

    @Test(
        "resolvedIdentity falls back to tokenStore when provided token contains newlines",
        .enabled(if: DataProtectionKeychainProbe.isWritable),
        arguments: [
            "malicious\ntoken",
            "malicious\rtoken",
            "malicious\r\ntoken",
            "token\r\nX-Injected: value"
        ]
    )
    func testResolvedIdentityFallsBackOnNewlineToken(maliciousToken: String) {
        let configuration = FeedbackClientConfiguration(
            baseURL: URL(string: "https://api.cupthread.com")!,
            appKey: "app_test_key"
        )
        let client = FeedbackClient(configuration: configuration)
        let storedToken = client.tokenStore.token

        #expect(client.resolvedIdentity(maliciousToken) == storedToken)
    }

    @Test("resolvedIdentity returns provided valid token")
    func testResolvedIdentityReturnsValidToken() {
        let configuration = FeedbackClientConfiguration(
            baseURL: URL(string: "https://api.cupthread.com")!,
            appKey: "app_test_key"
        )
        let client = FeedbackClient(configuration: configuration)
        let validToken = "usr_valid_single_line_12345"

        #expect(client.resolvedIdentity(validToken) == validToken)
    }

    @Test(
        "resolvedIdentity falls back to tokenStore when token is nil, empty, or whitespace",
        .enabled(if: DataProtectionKeychainProbe.isWritable)
    )
    func testResolvedIdentityFallsBackOnNilOrEmpty() {
        let configuration = FeedbackClientConfiguration(
            baseURL: URL(string: "https://api.cupthread.com")!,
            appKey: "app_test_key"
        )
        let client = FeedbackClient(configuration: configuration)
        let storedToken = client.tokenStore.token

        #expect(client.resolvedIdentity(nil) == storedToken)
        #expect(client.resolvedIdentity("") == storedToken)
        #expect(client.resolvedIdentity("   ") == storedToken)
        #expect(client.resolvedIdentity("\r\n") == storedToken)
        #expect(client.resolvedIdentity(" \n ") == storedToken)
    }

    @Test(
        "resolvedSubmitUserToken rejects tokens with newlines",
        .enabled(if: DataProtectionKeychainProbe.isWritable)
    )
    func testResolvedSubmitUserTokenRejectsNewlines() {
        let configuration = FeedbackClientConfiguration(
            baseURL: URL(string: "https://api.cupthread.com")!,
            appKey: "app_test_key"
        )
        let client = FeedbackClient(configuration: configuration)
        let maliciousToken = "malicious\r\ntoken"
        let storedToken = client.tokenStore.token

        #expect(client.resolvedSubmitUserToken(maliciousToken, hasAttachments: false) == nil)
        #expect(client.resolvedSubmitUserToken(maliciousToken, hasAttachments: true) == storedToken)
    }

    @Test("resolvedSubmitUserToken returns valid token regardless of attachments flag")
    func testResolvedSubmitUserTokenAcceptsValidToken() {
        let configuration = FeedbackClientConfiguration(
            baseURL: URL(string: "https://api.cupthread.com")!,
            appKey: "app_test_key"
        )
        let client = FeedbackClient(configuration: configuration)
        let validToken = "valid_token_123"

        #expect(client.resolvedSubmitUserToken(validToken, hasAttachments: false) == validToken)
        #expect(client.resolvedSubmitUserToken(validToken, hasAttachments: true) == validToken)
    }

    @Test("Wire level: fetchFeatureRequests rejects newline-bearing userToken without network (SEC-30, #497)")
    func testWireLevelEndpointRejectsNewlineBearingUserToken() async {
        let capture = CaptureBox<URLRequest>()
        let host = "usertoken-crlf-test.example.com"
        MockURLProtocol.setHandler(forHost: host) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["requests": [String](), "total": 0]))
        }
        defer { MockURLProtocol.setHandler(forHost: host, nil) }
        let client = makeClient(baseURL: URL(string: "https://\(host)")!)
        let maliciousToken = "malicious\r\nX-Injected: value"

        await #expect(throws: FeedbackClientError.authenticationRequired) {
            _ = try await client.fetchFeatureRequests(userToken: maliciousToken)
        }

        #expect(capture.value == nil)
    }

    @Test("Wire level: submit with attachments rejects newline-bearing userToken without falling back to tokenStore (SEC-30, #497)")
    func testWireLevelSubmitWithAttachmentsRejectsNewlineBearingUserToken() async {
        let capture = CaptureBox<URLRequest>()
        let host = "usertoken-crlf-submit.example.com"
        MockURLProtocol.setHandler(forHost: host) { request in
            capture.value = request
            return (makeHTTPResponse(status: 201), try encodeJSON(["feedbackId": "fb-123"]))
        }
        defer { MockURLProtocol.setHandler(forHost: host, nil) }
        let client = makeClient(baseURL: URL(string: "https://\(host)")!)
        let maliciousToken = "malicious\r\nX-Injected: value"
        var draft = FeedbackDraft(
            title: "Attachment fallback",
            description: "Valid description",
            platform: .ios
        )
        draft.attachments = [FeedbackAttachment(
            kind: .image,
            uploadId: "upl-123",
            key: "upl-123",
            url: URL(string: "https://\(host)/shot.png")!
        )]

        await #expect(throws: FeedbackClientError.authenticationRequired) {
            _ = try await client.submit(draft, userToken: maliciousToken)
        }

        #expect(capture.value == nil)
    }
}
