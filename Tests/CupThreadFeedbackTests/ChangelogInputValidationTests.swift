import Foundation
import Testing
@testable import CupThreadFeedback

// Regression tests for #419: subscribeToChangelog must reject a blank or
// multi-line userToken (the header would otherwise be dropped and the
// subscription recorded anonymously) and an implausible email (the server
// can only answer 400), and unsubscribeFromChangelog must reject a blank
// token instead of dispatching the destructive POST with `token=`. All
// rejections happen locally — the capture asserts zero network requests.
// Lives in its own suite (and host) so it can run in parallel with the
// other validation suites.
@Suite("ChangelogInputValidation", .serialized)
struct ChangelogInputValidationTests {
    static let apiHost = "changelog-input-validation.example.com"

    static func makeValidatedClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(apiHost)")!)
    }

    static func stubSubscribeResponse(_ capture: CaptureBox<URLRequest>) {
        MockURLProtocol.setHandler(forHost: apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(status: 201), try encodeJSON(["subscribed": true]))
        }
    }

    static func stubUnsubscribeResponse(_ capture: CaptureBox<URLRequest>) {
        MockURLProtocol.setHandler(forHost: apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["unsubscribed": true]))
        }
    }

    // MARK: - subscribe email validation

    @Test func subscribeRejectsBlankEmailWithoutNetwork() async {
        let capture = CaptureBox<URLRequest>()
        Self.stubSubscribeResponse(capture)

        for blankEmail in ["", "   ", " \n\t "] {
            do {
                _ = try await Self.makeValidatedClient().subscribeToChangelog(
                    email: blankEmail,
                    userToken: "tok-1"
                )
                Issue.record("Expected blank email \(blankEmail.debugDescription) to be rejected")
            } catch {
                Self.expectLocalBadRequest(error)
            }
        }

        #expect(capture.value == nil, "no network request may be built for a blank email")
    }

    @Test func subscribeRejectsImplausibleEmailWithoutNetwork() async {
        let capture = CaptureBox<URLRequest>()
        Self.stubSubscribeResponse(capture)

        for badEmail in ["not-an-email", "foo@", "@example.com", "user@@example.com",
                         "user@example..com", "user@example.", "user name@example.com"] {
            do {
                _ = try await Self.makeValidatedClient().subscribeToChangelog(
                    email: badEmail,
                    userToken: "tok-1"
                )
                Issue.record("Expected email \(badEmail.debugDescription) to be rejected")
            } catch {
                Self.expectLocalBadRequest(error)
            }
        }

        #expect(capture.value == nil, "no network request may be built for an implausible email")
    }

    @Test func subscribeAcceptsPlausibleEmailAndTrimsPadding() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubSubscribeResponse(capture)

        let result = try await Self.makeValidatedClient().subscribeToChangelog(
            email: "  user@example.com  ",
            userToken: "  tok-1  "
        )

        #expect(result.subscribed == true)
        let request = try #require(capture.value)
        #expect(request.value(forHTTPHeaderField: "X-User-Token") == "tok-1")
        let rawData = try #require(bodyData(from: request))
        let json = try #require(parseJSONDict(rawData))
        #expect(json["email"] as? String == "user@example.com")
    }

    // MARK: - subscribe userToken validation

    @Test func subscribeRejectsBlankUserTokenWithoutNetwork() async {
        let capture = CaptureBox<URLRequest>()
        Self.stubSubscribeResponse(capture)

        for blankToken in ["", "   ", " \n\t "] {
            await #expect(throws: FeedbackClientError.authenticationRequired) {
                try await Self.makeValidatedClient().subscribeToChangelog(
                    email: "user@example.com",
                    userToken: blankToken
                )
            }
        }

        #expect(capture.value == nil, "no network request may be built for a blank token")
    }

    @Test func subscribeRejectsMultiLineUserTokenWithoutNetwork() async {
        let capture = CaptureBox<URLRequest>()
        Self.stubSubscribeResponse(capture)

        for multiLineToken in ["tok\n123", "tok\r\n123", "\n"] {
            await #expect(throws: FeedbackClientError.authenticationRequired) {
                try await Self.makeValidatedClient().subscribeToChangelog(
                    email: "user@example.com",
                    userToken: multiLineToken
                )
            }
        }

        #expect(capture.value == nil, "no network request may be built for a multi-line token")
    }

    // MARK: - unsubscribe token validation

    @Test func unsubscribeRejectsBlankTokenWithoutNetwork() async {
        let capture = CaptureBox<URLRequest>()
        Self.stubUnsubscribeResponse(capture)

        for blankToken in ["", "   ", " \n\t "] {
            do {
                _ = try await Self.makeValidatedClient().unsubscribeFromChangelog(token: blankToken)
                Issue.record("Expected blank token \(blankToken.debugDescription) to be rejected")
            } catch {
                Self.expectLocalBadRequest(error)
            }
        }

        #expect(capture.value == nil, "no network request may be built for a blank token")
    }

    @Test func unsubscribeTrimsWhitespacePaddedToken() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubUnsubscribeResponse(capture)

        let result = try await Self.makeValidatedClient().unsubscribeFromChangelog(
            token: "  signed-token-1  "
        )

        #expect(result.unsubscribed == true)
        let request = try #require(capture.value)
        let queryItems = try #require(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: true)?.queryItems
        )
        #expect(queryItems.first { $0.name == "token" }?.value == "signed-token-1")
    }

    // MARK: - Helpers

    /// A locally rejected input must surface as the `400`-shaped
    /// `unexpectedStatus` with `requestId == nil` — no server answered.
    private static func expectLocalBadRequest(_ error: Error) {
        guard case FeedbackClientError.unexpectedStatus(let code, let message, let requestId) = error else {
            Issue.record("Unexpected error type: \(error)")
            return
        }
        #expect(code == 400)
        #expect(requestId == nil, "a locally rejected request carries no server request id")
        #expect(!message.isEmpty)
    }
}
