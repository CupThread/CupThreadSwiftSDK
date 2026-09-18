import Foundation
import Testing
@testable import CupThreadFeedback

// All network tests share the static MockURLProtocol handler, so they run serialized.
// This suite uses its own base host so it can run in parallel with the other suites.
@Suite("WeeklyDigestUnsubscribe", .serialized)
struct WeeklyDigestUnsubscribeTests {
    static let apiHost = "digest.example.com"

    static func makeDigestClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(apiHost)")!)
    }

    // MARK: - Wire contract (POST /api/v1/public/digest/unsubscribe)

    @Test func unsubscribeSendsOneClickTokenInQueryString() async throws {
        // RFC 8058 one-click: the signed token rides as the `token` query
        // item on the POST, and the endpoint is not app-scoped — the token
        // alone identifies the workspace and recipient.
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["unsubscribed": true]))
        }

        let result = try await Self.makeDigestClient()
            .unsubscribeFromWeeklyDigest(token: "digest-signed-token-abc")

        let request = try #require(capture.value)
        #expect(request.url?.path == "/api/v1/public/digest/unsubscribe")
        #expect(request.httpMethod == "POST")
        let query = try #require(request.url?.query)
        #expect(query.contains("token=digest-signed-token-abc"))
        // The endpoint content-negotiates an HTML landing page for browsers;
        // without an explicit JSON preference the JSON result is not guaranteed.
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        // Mail-flow endpoint: correlation headers yes, session identity no.
        #expect(request.value(forHTTPHeaderField: "X-SDK-Version") == FeedbackClient.sdkVersion)
        #expect(request.value(forHTTPHeaderField: "X-Request-Id") != nil)
        #expect(request.value(forHTTPHeaderField: "X-User-Token") == nil)

        #expect(result.unsubscribed == true)
    }

    @Test func unsubscribeReplayStaysIdempotent() async throws {
        // Replaying the same signed token is idempotent: the server answers
        // the same uniform 200 whether or not this call performed the removal.
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(), try encodeJSON(["unsubscribed": true]))
        }

        let first = try await Self.makeDigestClient()
            .unsubscribeFromWeeklyDigest(token: "digest-signed-token-abc")
        let replay = try await Self.makeDigestClient()
            .unsubscribeFromWeeklyDigest(token: "digest-signed-token-abc")

        #expect(first.unsubscribed == true)
        #expect(replay.unsubscribed == true)
    }

    @Test func unsubscribeThrowsOnMissingInvalidOrExpiredToken() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 400), try encodeJSON(["error": "Invalid or expired token"]))
        }

        do {
            _ = try await Self.makeDigestClient()
                .unsubscribeFromWeeklyDigest(token: "stale-digest-token")
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            if case .unexpectedStatus(let code, let message, _) = error {
                #expect(code == 400)
                #expect(message == "Invalid or expired token")
            } else {
                Issue.record("Unexpected error type: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func unsubscribeMaps429ToRateLimited() async throws {
        // The endpoint rate limits per client IP.
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 429), try encodeJSON(["error": "Too many requests"]))
        }

        do {
            _ = try await Self.makeDigestClient()
                .unsubscribeFromWeeklyDigest(token: "digest-signed-token-abc")
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            guard case .rateLimited(let message, _) = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
            #expect(message == "Too many requests")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
