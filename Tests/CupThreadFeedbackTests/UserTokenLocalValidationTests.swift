import Foundation
import Testing
@testable import CupThreadFeedback

// Regression tests for #417: eraseMyData and updateUserAttributes must
// reject an empty, whitespace-only, or newline-containing userToken locally
// (applyUserToken would silently drop the `X-User-Token` header, dispatching
// an anonymous erasure or a signed report whose HMAC was computed over an
// un-trimmed token while the header carried the trimmed value), and
// updateUserAttributes must sign and send the same trimmed token so the
// signature always matches the header the server verifies. All rejections
// happen locally — the capture asserts zero network requests. Lives in its
// own suite (and host) so it can run in parallel with the other validation
// suites.
@Suite("UserTokenLocalValidation", .serialized)
struct UserTokenLocalValidationTests {
    static let apiHost = "usertoken-local-validation.example.com"
    static let testSecret = "sec_test_secret_key_12345"
    static let testAppKey = "app_testkey123456"

    static func stubEraseResponse(_ capture: CaptureBox<URLRequest>) {
        MockURLProtocol.setHandler(forHost: apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["erased": true, "endUserId": "enduser-1"]))
        }
    }

    static func stubUpdateResponse(_ capture: CaptureBox<URLRequest>) {
        MockURLProtocol.setHandler(forHost: apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["ok": true, "updatedAt": "2026-09-16T00:00:00.000Z"]))
        }
    }

    static func makeSigningClient() -> FeedbackClient {
        makeClient(
            baseURL: URL(string: "https://\(apiHost)")!,
            appKey: testAppKey,
            signingSecret: testSecret
        )
    }

    // MARK: - eraseMyData token validation

    @Test func eraseRejectsBlankUserTokenWithoutNetwork() async {
        let capture = CaptureBox<URLRequest>()
        Self.stubEraseResponse(capture)

        for blankToken in ["", "   ", " \n\t "] {
            await #expect(throws: FeedbackClientError.authenticationRequired) {
                try await Self.makeSigningClient().eraseMyData(userToken: blankToken)
            }
        }

        #expect(capture.value == nil, "no network request may be built for a blank token")
    }

    @Test func eraseRejectsMultiLineUserTokenWithoutNetwork() async {
        let capture = CaptureBox<URLRequest>()
        Self.stubEraseResponse(capture)

        for multiLineToken in ["tok\n123", "tok\r\n123", "tok\r\nInjected: evil", "\n"] {
            await #expect(throws: FeedbackClientError.authenticationRequired) {
                try await Self.makeSigningClient().eraseMyData(userToken: multiLineToken)
            }
        }

        #expect(capture.value == nil, "no network request may be built for a multi-line token")
    }

    @Test func eraseTrimsWhitespacePaddedToken() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubEraseResponse(capture)

        let result = try await Self.makeSigningClient().eraseMyData(userToken: "  tok-1  ")

        #expect(result.erased == true)
        let request = try #require(capture.value)
        #expect(request.value(forHTTPHeaderField: "X-User-Token") == "tok-1")
    }

    // MARK: - updateUserAttributes token validation

    @Test func updateUserAttributesRejectsBlankUserTokenWithoutNetwork() async {
        let capture = CaptureBox<URLRequest>()
        Self.stubUpdateResponse(capture)

        for blankToken in ["", "   ", " \n\t "] {
            await #expect(throws: FeedbackClientError.authenticationRequired) {
                try await Self.makeSigningClient().updateUserAttributes(
                    isPaying: .value(true),
                    userToken: blankToken
                )
            }
        }

        #expect(capture.value == nil, "no network request may be built for a blank token")
    }

    @Test func updateUserAttributesRejectsMultiLineUserTokenWithoutNetwork() async {
        let capture = CaptureBox<URLRequest>()
        Self.stubUpdateResponse(capture)

        for multiLineToken in ["tok\n123", "tok\r\n123", "tok\r\nX-Evil: injected", "\n"] {
            await #expect(throws: FeedbackClientError.authenticationRequired) {
                try await Self.makeSigningClient().updateUserAttributes(
                    isPaying: .value(true),
                    userToken: multiLineToken
                )
            }
        }

        #expect(capture.value == nil, "no network request may be built for a multi-line token")
    }

    // MARK: - Signature / header synchronization

    @Test func updateUserAttributesSignsAndSendsSameTrimmedToken() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubUpdateResponse(capture)

        // Before #417 the HMAC was computed over the padded token while
        // applyUserToken sent the trimmed value in `X-User-Token` — a
        // guaranteed 401 invalid_signature on the server.
        let fixedTimestamp: Int64 = 1773600200
        let result = try await Self.makeSigningClient().updateUserAttributes(
            isPaying: true,
            plan: "pro",
            mrr: 12.5,
            currency: "EUR",
            userToken: "  tok-pad-1  ",
            timestamp: fixedTimestamp
        )

        #expect(result.ok == true)
        let request = try #require(capture.value)
        #expect(request.value(forHTTPHeaderField: "X-User-Token") == "tok-pad-1")

        let rawData = try #require(bodyData(from: request))
        let json = try #require(parseJSONDict(rawData))
        let signature = try #require(json["signature"] as? String)
        let expectedCanonical = UserAttributesSigner.canonicalString(
            for: .init(
                appKey: Self.testAppKey,
                userToken: "tok-pad-1",
                isPaying: true,
                plan: "pro",
                mrr: 12.5,
                currency: "EUR",
                timestamp: fixedTimestamp
            )
        )
        let expectedSignature = UserAttributesSigner.signature(for: expectedCanonical, secret: Self.testSecret)
        #expect(signature == expectedSignature)
    }
}
