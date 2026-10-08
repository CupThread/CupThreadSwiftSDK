import Foundation
import Testing
@testable import CupThreadFeedback

// Issue #248: the four public read surfaces (feature-request comments,
// changelog feed, roadmap columns, versions) are rate-limited per client IP
// and may serve anonymous reads from a short-lived shared cache. A 429 on
// these GETs must surface as the typed, retryable `.rateLimited` error with
// curated copy — never as `.unexpectedStatus` carrying the raw JSON body.
@Suite("ReadEndpointsRateLimit", .serialized)
struct ReadEndpointsRateLimitTests {
    static let apiHost = "read-429.example.com"
    static var rateLimitBody: [String: Any] {
        ["error": "Too many requests. Please try again shortly."]
    }

    static func makeAPIClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(apiHost)")!)
    }

    static func setRateLimitedHandler() throws {
        MockURLProtocol.setHandler(forHost: apiHost) { _ in
            (
                makeHTTPResponse(status: 429, headers: ["X-Request-Id": "req-429-read1"]),
                try encodeJSON(rateLimitBody)
            )
        }
    }

    // MARK: - Wire mapping

    @Test func commentsPageMaps429ToRateLimited() async throws {
        try Self.setRateLimitedHandler()

        do {
            _ = try await Self.makeAPIClient().fetchComments(featureRequestId: "fr-1", limit: 50)
            Issue.record("Expected rateLimited")
        } catch let error as FeedbackClientError {
            guard case .rateLimited(let message, let requestId) = error else {
                Issue.record("Expected .rateLimited, got \(error)")
                return
            }
            #expect(message == Self.rateLimitBody["error"] as? String)
            #expect(requestId == "req-429-read1")
        }
    }

    @Test func commentsWalkMaps429ToRateLimited() async throws {
        try Self.setRateLimitedHandler()

        do {
            _ = try await Self.makeAPIClient().fetchComments(featureRequestId: "fr-1", maxPages: 3)
            Issue.record("Expected rateLimited")
        } catch let error as FeedbackClientError {
            guard case .rateLimited = error else {
                Issue.record("Expected .rateLimited, got \(error)")
                return
            }
        }
    }

    @Test func changelogPageMaps429ToRateLimited() async throws {
        try Self.setRateLimitedHandler()

        do {
            _ = try await Self.makeAPIClient().fetchChangelog(limit: 50)
            Issue.record("Expected rateLimited")
        } catch let error as FeedbackClientError {
            guard case .rateLimited(let message, let requestId) = error else {
                Issue.record("Expected .rateLimited, got \(error)")
                return
            }
            #expect(message == Self.rateLimitBody["error"] as? String)
            #expect(requestId == "req-429-read1")
        }
    }

    @Test func changelogWalkMaps429ToRateLimited() async throws {
        try Self.setRateLimitedHandler()

        do {
            _ = try await Self.makeAPIClient().fetchChangelog(maxPages: 3)
            Issue.record("Expected rateLimited")
        } catch let error as FeedbackClientError {
            guard case .rateLimited = error else {
                Issue.record("Expected .rateLimited, got \(error)")
                return
            }
        }
    }

    @Test func columnsMap429ToRateLimited() async throws {
        try Self.setRateLimitedHandler()

        do {
            _ = try await Self.makeAPIClient().fetchColumns()
            Issue.record("Expected rateLimited")
        } catch let error as FeedbackClientError {
            guard case .rateLimited(let message, let requestId) = error else {
                Issue.record("Expected .rateLimited, got \(error)")
                return
            }
            #expect(message == Self.rateLimitBody["error"] as? String)
            #expect(requestId == "req-429-read1")
        }
    }

    @Test func versionsMap429ToRateLimited() async throws {
        try Self.setRateLimitedHandler()

        do {
            _ = try await Self.makeAPIClient().fetchVersions()
            Issue.record("Expected rateLimited")
        } catch let error as FeedbackClientError {
            guard case .rateLimited(let message, let requestId) = error else {
                Issue.record("Expected .rateLimited, got \(error)")
                return
            }
            #expect(message == Self.rateLimitBody["error"] as? String)
            #expect(requestId == "req-429-read1")
        }
    }

    // MARK: - User-facing copy

    @Test func rateLimitedOnReadsRendersCuratedCopyWithoutServerText() throws {
        try Self.setRateLimitedHandler()

        let error = FeedbackClientError.rateLimited(
            message: Self.rateLimitBody["error"] as? String,
            requestId: "req-429-read1"
        )
        let expected = CupThreadStrings.tr("cupthread.error.http_rate_limited") + " (request id: req-429-read1)"
        #expect(error.errorDescription == expected)
        #expect(!error.errorDescription!.contains("Too many requests"))
        #expect(error.responseBody == nil, "raw server text must stay off responseBody")
        #expect(FriendlyError.message(for: error) == expected)
    }
}
