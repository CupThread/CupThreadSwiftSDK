import Foundation
import Testing
@testable import CupThreadFeedback

// Regression tests for #425: the paginated list endpoints must normalize
// their query parameters client-side, since the gateway rejects page sizes
// outside the documented 1...max range with 400 and blank cursors decode
// as garbage server-side. Lives in its own suite (and host) so it can run
// in parallel with the cursor-walk pagination suites.
@Suite("PaginationParameterValidation", .serialized)
struct PaginationParameterValidationTests {
    static let apiHost = "pagination-validation.example.com"

    static func makeValidatedClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(apiHost)")!)
    }

    // MARK: - fetchChangelog limit clamping

    @Test func fetchChangelogPageClampsNonPositiveLimitToOne() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["entries": []]))
        }

        for invalidLimit in [0, -10] {
            _ = try await Self.makeValidatedClient().fetchChangelog(limit: invalidLimit)
            let request = try #require(capture.value)
            #expect(queryItems(of: request)["limit"] == "1")
        }
    }

    @Test func fetchChangelogPageClampsOversizedLimitToServerMaximum() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["entries": []]))
        }

        _ = try await Self.makeValidatedClient().fetchChangelog(limit: 500)

        let request = try #require(capture.value)
        #expect(queryItems(of: request)["limit"] == "100")
    }

    @Test func fetchChangelogPageKeepsInBoundLimitUntouched() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["entries": []]))
        }

        _ = try await Self.makeValidatedClient().fetchChangelog(limit: 50)

        let request = try #require(capture.value)
        #expect(queryItems(of: request)["limit"] == "50")
    }

    // MARK: - fetchChangelog cursor sanitization

    @Test func fetchChangelogPageDropsWhitespaceOnlyCursor() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["entries": []]))
        }

        _ = try await Self.makeValidatedClient().fetchChangelog(limit: 50, cursor: " \n\t ")

        let request = try #require(capture.value)
        #expect(request.url?.query?.contains("cursor=") == false)
    }

    @Test func fetchChangelogPageTrimsWhitespacePaddedCursor() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["entries": []]))
        }

        _ = try await Self.makeValidatedClient().fetchChangelog(limit: 50, cursor: "  MjAyNi0w  ")

        let request = try #require(capture.value)
        #expect(queryItems(of: request)["cursor"] == "MjAyNi0w")
    }

    // MARK: - fetchComments limit clamping

    @Test func fetchCommentPageClampsNonPositiveLimitToOne() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["comments": []]))
        }

        for invalidLimit in [0, -10] {
            _ = try await Self.makeValidatedClient().fetchComments(
                featureRequestId: "fr-123",
                limit: invalidLimit
            )
            let request = try #require(capture.value)
            #expect(queryItems(of: request)["limit"] == "1")
        }
    }

    @Test func fetchCommentPageClampsOversizedLimitToServerMaximum() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["comments": []]))
        }

        _ = try await Self.makeValidatedClient().fetchComments(featureRequestId: "fr-123", limit: 500)

        let request = try #require(capture.value)
        #expect(queryItems(of: request)["limit"] == "200")
    }

    @Test func fetchCommentPageKeepsInBoundLimitUntouched() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["comments": []]))
        }

        _ = try await Self.makeValidatedClient().fetchComments(featureRequestId: "fr-123", limit: 20)

        let request = try #require(capture.value)
        #expect(queryItems(of: request)["limit"] == "20")
    }

    // MARK: - fetchComments cursor sanitization

    @Test func fetchCommentPageDropsWhitespaceOnlyCursor() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["comments": []]))
        }

        _ = try await Self.makeValidatedClient().fetchComments(
            featureRequestId: "fr-123",
            limit: 200,
            cursor: " \n\t "
        )

        let request = try #require(capture.value)
        #expect(request.url?.query?.contains("cursor=") == false)
    }

    @Test func fetchCommentPageTrimsWhitespacePaddedCursor() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["comments": []]))
        }

        _ = try await Self.makeValidatedClient().fetchComments(
            featureRequestId: "fr-123",
            limit: 200,
            cursor: "  MjAyNi0w  "
        )

        let request = try #require(capture.value)
        #expect(queryItems(of: request)["cursor"] == "MjAyNi0w")
    }
}

// MARK: - Helpers

private func queryItems(of request: URLRequest) -> [String: String] {
    guard let url = request.url,
          let items = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems
    else { return [:] }
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
}
