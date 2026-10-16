import Foundation
import Testing
@testable import CupThreadFeedback

// Regression tests for #422: fetchFeatureRequests must reject a blank
// userToken before any network I/O (the header would otherwise be dropped
// and the response would read as anonymous, reporting false hasVoted), and
// normalize its pagination and filter query parameters client-side like the
// other paginated list endpoints (#425). Lives in its own suite (and host)
// so it can run in parallel with the other validation suites.
@Suite("FeatureRequestListInputValidation", .serialized)
struct FeatureRequestListInputValidationTests {
    static let apiHost = "feature-list-validation.example.com"

    static func makeValidatedClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(apiHost)")!)
    }

    static func stubListResponse(_ capture: CaptureBox<URLRequest>) {
        MockURLProtocol.setHandler(forHost: apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["requests": [], "total": 0]))
        }
    }

    // MARK: - userToken rejection

    @Test func blankUserTokenThrowsAuthenticationRequiredWithoutNetwork() async {
        let capture = CaptureBox<URLRequest>()
        Self.stubListResponse(capture)

        for blankToken in ["", "   ", " \n\t "] {
            await #expect(throws: FeedbackClientError.authenticationRequired) {
                try await Self.makeValidatedClient().fetchFeatureRequests(userToken: blankToken)
            }
        }

        #expect(capture.value == nil, "no network request may be built for a blank token")
    }

    @Test func whitespacePaddedUserTokenIsAcceptedAndTrimmed() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubListResponse(capture)

        _ = try await Self.makeValidatedClient().fetchFeatureRequests(userToken: "  tok-1  ")

        let request = try #require(capture.value)
        #expect(request.value(forHTTPHeaderField: "X-User-Token") == "tok-1")
    }

    // MARK: - limit clamping

    @Test func fetchFeatureRequestsClampsNonPositiveLimitToOne() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubListResponse(capture)

        for invalidLimit in [0, -10] {
            _ = try await Self.makeValidatedClient().fetchFeatureRequests(
                userToken: "tok-1",
                limit: invalidLimit
            )
            let request = try #require(capture.value)
            #expect(queryItems(of: request)["limit"] == "1")
        }
    }

    @Test func fetchFeatureRequestsClampsOversizedLimitToServerMaximum() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubListResponse(capture)

        _ = try await Self.makeValidatedClient().fetchFeatureRequests(userToken: "tok-1", limit: 500)

        let request = try #require(capture.value)
        #expect(queryItems(of: request)["limit"] == "200")
    }

    @Test func fetchFeatureRequestsKeepsInBoundLimitUntouched() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubListResponse(capture)

        for validLimit in [1, 50, 200] {
            _ = try await Self.makeValidatedClient().fetchFeatureRequests(
                userToken: "tok-1",
                limit: validLimit
            )
            let request = try #require(capture.value)
            #expect(queryItems(of: request)["limit"] == String(validLimit))
        }
    }

    // MARK: - offset clamping

    @Test func fetchFeatureRequestsClampsNegativeOffsetToZero() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubListResponse(capture)

        _ = try await Self.makeValidatedClient().fetchFeatureRequests(userToken: "tok-1", offset: -5)

        let request = try #require(capture.value)
        #expect(queryItems(of: request)["offset"] == "0")
    }

    @Test func fetchFeatureRequestsKeepsNonNegativeOffsetUntouched() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubListResponse(capture)

        _ = try await Self.makeValidatedClient().fetchFeatureRequests(userToken: "tok-1", offset: 40)

        let request = try #require(capture.value)
        #expect(queryItems(of: request)["offset"] == "40")
    }

    // MARK: - versionId / query / cursor sanitization

    @Test func fetchFeatureRequestsDropsWhitespaceOnlyVersionIdQueryAndCursor() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubListResponse(capture)

        _ = try await Self.makeValidatedClient().fetchFeatureRequests(
            userToken: "tok-1",
            versionId: "   ",
            query: " \n\t ",
            cursor: "\t "
        )

        let request = try #require(capture.value)
        let query = request.url?.query
        #expect(query?.contains("versionId=") == false)
        #expect(query?.contains("q=") == false)
        #expect(query?.contains("cursor=") == false)
    }

    @Test func fetchFeatureRequestsTrimsWhitespacePaddedVersionIdQueryAndCursor() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubListResponse(capture)

        _ = try await Self.makeValidatedClient().fetchFeatureRequests(
            userToken: "tok-1",
            versionId: " v-9 ",
            query: "  dark mode  ",
            cursor: "  MjAyNi0w  "
        )

        let request = try #require(capture.value)
        #expect(queryItems(of: request)["versionId"] == "v-9")
        #expect(queryItems(of: request)["q"] == "dark mode")
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
