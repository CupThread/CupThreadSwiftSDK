import Foundation
import Testing
@testable import CupThreadFeedback

// Regression tests for #416: linkEndUser must reject a blank,
// whitespace-only, or newline-containing sessionToken (a blank session
// would dispatch `Bearer ` with no identity, a newline can never be carried
// as a header value) and an identically malformed userToken (the header
// plumbing would silently drop `X-User-Token`, dispatching the link with no
// anonymous identity to attach), and unsubscribeFromWeeklyDigest must
// reject a blank token instead of dispatching the mutating POST with
// `token=` — the same contract as the changelog unsubscribe sibling (#419).
// All rejections happen locally — the capture asserts zero network
// requests. Lives in its own suite (and host) so it can run in parallel
// with the other validation suites.
@Suite("EndUserTokenLocalValidation", .serialized)
struct EndUserTokenLocalValidationTests {
    static let apiHost = "enduser-token-local-validation.example.com"

    static func stubLinkResponse(_ capture: CaptureBox<URLRequest>) {
        MockURLProtocol.setHandler(forHost: apiHost) { request in
            capture.value = request
            return (
                makeHTTPResponse(),
                try encodeJSON(["linked": true, "endUserId": "enduser-1", "clerkUserId": "user_1"])
            )
        }
    }

    static func stubDigestUnsubscribeResponse(_ capture: CaptureBox<URLRequest>) {
        MockURLProtocol.setHandler(forHost: apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["unsubscribed": true]))
        }
    }

    static func makeValidatedClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(apiHost)")!)
    }

    private static func expectAuthenticationRequired(_ error: Error) {
        guard case FeedbackClientError.authenticationRequired = error else {
            Issue.record("Unexpected error type: \(error)")
            return
        }
    }

    /// A locally rejected unsubscribe token must surface as the typed
    /// ``invalidInput`` case naming `token` (#620) — not a fabricated
    /// server-shaped status: no server answered, so there is no status code
    /// and no request id to quote.
    private static func expectLocalInvalidToken(_ error: Error) {
        guard case FeedbackClientError.invalidInput(let field) = error else {
            Issue.record("Unexpected error type: \(error)")
            return
        }
        #expect(field == "token")
    }

    // MARK: - linkEndUser sessionToken validation

    @Test func linkEndUserRejectsBlankSessionTokenWithoutNetwork() async {
        let capture = CaptureBox<URLRequest>()
        Self.stubLinkResponse(capture)

        for blankSession in ["", "   ", " \n\t "] {
            await #expect(
                throws: FeedbackClientError.authenticationRequired,
                "blank session \(blankSession.debugDescription) must be rejected locally"
            ) {
                try await Self.makeValidatedClient().linkEndUser(
                    sessionToken: blankSession,
                    userToken: "tok-1"
                )
            }
        }

        #expect(capture.value == nil, "no network request may be built for a blank session token")
    }

    @Test func linkEndUserRejectsMultiLineSessionTokenWithoutNetwork() async {
        let capture = CaptureBox<URLRequest>()
        Self.stubLinkResponse(capture)

        for multiLineSession in ["sess\n123", "sess\r\n123", "sess\r\nInjected-Header: evil", "\n"] {
            await #expect(throws: FeedbackClientError.authenticationRequired) {
                try await Self.makeValidatedClient().linkEndUser(
                    sessionToken: multiLineSession,
                    userToken: "tok-1"
                )
            }
        }

        #expect(capture.value == nil, "no network request may be built for a multi-line session token")
    }

    // MARK: - linkEndUser userToken validation

    @Test func linkEndUserRejectsBlankUserTokenWithoutNetwork() async {
        let capture = CaptureBox<URLRequest>()
        Self.stubLinkResponse(capture)

        for blankToken in ["", "   ", " \n\t "] {
            await #expect(throws: FeedbackClientError.authenticationRequired) {
                try await Self.makeValidatedClient().linkEndUser(
                    sessionToken: "sess-1",
                    userToken: blankToken
                )
            }
        }

        #expect(capture.value == nil, "no network request may be built for a blank user token")
    }

    @Test func linkEndUserRejectsMultiLineUserTokenWithoutNetwork() async {
        let capture = CaptureBox<URLRequest>()
        Self.stubLinkResponse(capture)

        for multiLineToken in ["tok\n123", "tok\r\n123", "tok\r\nX-Evil: injected", "\n"] {
            await #expect(throws: FeedbackClientError.authenticationRequired) {
                try await Self.makeValidatedClient().linkEndUser(
                    sessionToken: "sess-1",
                    userToken: multiLineToken
                )
            }
        }

        #expect(capture.value == nil, "no network request may be built for a multi-line user token")
    }

    // MARK: - Trimmed values on the wire

    @Test func linkEndUserSendsTrimmedSessionAndUserTokens() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubLinkResponse(capture)

        let result = try await Self.makeValidatedClient().linkEndUser(
            sessionToken: "  sess-pad-1  ",
            userToken: "  tok-pad-1  "
        )

        #expect(result.linked == true)
        let request = try #require(capture.value)
        #expect(request.url?.path == "/api/v1/me/link")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sess-pad-1")
        #expect(request.value(forHTTPHeaderField: "X-User-Token") == "tok-pad-1")
    }

    // MARK: - unsubscribeFromWeeklyDigest token validation

    @Test func unsubscribeFromWeeklyDigestRejectsBlankTokenWithoutNetwork() async {
        let capture = CaptureBox<URLRequest>()
        Self.stubDigestUnsubscribeResponse(capture)

        for blankToken in ["", "   ", " \n\t "] {
            do {
                _ = try await Self.makeValidatedClient().unsubscribeFromWeeklyDigest(token: blankToken)
                Issue.record("Expected blank token \(blankToken.debugDescription) to be rejected")
            } catch {
                Self.expectLocalInvalidToken(error)
            }
        }

        #expect(capture.value == nil, "no network request may be built for a blank token")
    }

    @Test func unsubscribeFromWeeklyDigestSendsTrimmedToken() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubDigestUnsubscribeResponse(capture)

        let result = try await Self.makeValidatedClient().unsubscribeFromWeeklyDigest(token: "  tok-pad-1  ")

        #expect(result.unsubscribed == true)
        let request = try #require(capture.value)
        #expect(request.url?.path == "/api/v1/public/digest/unsubscribe")
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first { $0.name == "token" }?.value == "tok-pad-1")
    }
}
