import Foundation
import Testing
@testable import CupThreadFeedback

// Regression tests for #601: URLComponents.queryItems percent-encodes per
// RFC 3986, under which `+` is a legal literal query character, so it emits
// `+` raw — but the API server decodes query values with form semantics
// (Hono rewrites `+` to a space before percent-decoding), silently turning
// a search for "C++" into "C". The assertions here intentionally inspect the
// RAW query string (`percentEncodedQuery`), not decoded `queryItems`:
// Foundation decodes `%2B` and `+` identically, so a decoded assertion would
// pass even while the wire bytes are wrong.
@Suite("QueryPlusEncoding", .serialized)
struct QueryPlusEncodingTests {
    static let apiHost = "query-plus.example.com"
    static let digestHost = "query-plus-digest.example.com"

    // MARK: - The search `q` sink (the live bug)

    @Test func searchQueryWithPlusIsSentAsPercentEncodedPlus() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubListResponse(capture)

        _ = try await Self.makePlusTestClient().fetchFeatureRequests(userToken: "tok-1", query: "C++")

        let request = try #require(capture.value)
        let rawQuery = try #require(request.url?.query)
        #expect(rawQuery.contains("q=C%2B%2B"), "raw wire bytes must carry %2B, got: \(rawQuery)")
        // And the value still reads back as the typed term.
        #expect(decodedQueryItems(of: request)["q"] == "C++")
    }

    @Test func searchQueryEncodesPlusSpaceAndEqualsDistinctly() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubListResponse(capture)

        _ = try await Self.makePlusTestClient().fetchFeatureRequests(userToken: "tok-1", query: "1+1 = 2")

        let request = try #require(capture.value)
        let rawQuery = try #require(request.url?.query)
        #expect(rawQuery.contains("q=1%2B1%20%3D%202"), "got: \(rawQuery)")
        #expect(decodedQueryItems(of: request)["q"] == "1+1 = 2")
    }

    @Test func searchQuerySpacesStayPercentEncodedNotPlus() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubListResponse(capture)

        _ = try await Self.makePlusTestClient().fetchFeatureRequests(userToken: "tok-1", query: "dark mode")

        let request = try #require(capture.value)
        let rawQuery = try #require(request.url?.query)
        #expect(rawQuery.contains("q=dark%20mode"), "no regression to +-for-space, got: \(rawQuery)")
        #expect(rawQuery.contains("+") == false)
    }

    @Test func searchQueryExistingPercentIsEncodedExactlyOnce() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubListResponse(capture)

        _ = try await Self.makePlusTestClient().fetchFeatureRequests(userToken: "tok-1", query: "50% off")

        let request = try #require(capture.value)
        let rawQuery = try #require(request.url?.query)
        #expect(rawQuery.contains("q=50%25%20off"), "got: \(rawQuery)")
        // The inserted %2B rewrite must not re-encode an existing %25.
        #expect(rawQuery.contains("%252") == false)
        #expect(decodedQueryItems(of: request)["q"] == "50% off")
    }

    @Test func cursorAndVersionIdRemainByteIdentical() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubListResponse(capture)

        _ = try await Self.makePlusTestClient().fetchFeatureRequests(
            userToken: "tok-1",
            versionId: "v-9",
            query: "C++",
            cursor: "MjAyNi0w"
        )

        let request = try #require(capture.value)
        let rawQuery = try #require(request.url?.query)
        // Base64url cursors and version ids cannot contain `+`; the rewrite
        // must leave their bytes exactly as before the change.
        #expect(rawQuery.contains("versionId=v-9"))
        #expect(rawQuery.contains("cursor=MjAyNi0w"))
    }

    // MARK: - Defense-in-depth sinks

    @Test func digestUnsubscribeTokenWithPlusIsPercentEncoded() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.digestHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["unsubscribed": true]))
        }

        _ = try await Self.makePlusTestDigestClient().unsubscribeFromWeeklyDigest(token: "tok+en")

        let request = try #require(capture.value)
        let rawQuery = try #require(request.url?.query)
        #expect(rawQuery.contains("token=tok%2Ben"), "got: \(rawQuery)")
        #expect(decodedQueryItems(of: request)["token"] == "tok+en")
    }

    @Test func thumbnailHintKeepsServerEncodedPlusNormalized() {
        // A server-issued `%2B` round-trips through `queryItems` (which
        // decodes it to `+` for the read-modify-write); the helper must
        // re-normalize it instead of de-normalizing it to a raw `+` that a
        // form-decoding server would read as a space.
        let url = URL(string: "https://\(Self.apiHost)/api/v1/files/key?name=foo%2Bbar.png")!

        let thumb = publicImageThumbnailURL(for: url, width: .w64)

        let components = URLComponents(url: thumb, resolvingAgainstBaseURL: false)
        let rawQuery = components?.percentEncodedQuery
        #expect(rawQuery?.contains("name=foo%2Bbar.png") == true, "got: \(rawQuery ?? "nil")")
        #expect(rawQuery?.contains("width=64") == true)
    }

    // MARK: - The shared helper itself

    @Test func helperEncodesLiteralPlusAndLeavesPercentEscapesUntouched() {
        var components = URLComponents(string: "https://\(Self.apiHost)/x")!

        components.setQueryItemsEncodingPlus([URLQueryItem(name: "q", value: "C++")])
        #expect(components.percentEncodedQuery == "q=C%2B%2B")

        // A value that literally spells "%2B" has its % encoded once, like
        // any other character — the helper's rewrite cannot double-encode it.
        components.setQueryItemsEncodingPlus([URLQueryItem(name: "q", value: "a%2Bb")])
        #expect(components.percentEncodedQuery == "q=a%252Bb")

        components.setQueryItemsEncodingPlus([URLQueryItem(name: "q", value: "a b=c&d")])
        #expect(components.percentEncodedQuery == "q=a%20b%3Dc%26d")

        // Empty input degrades to Foundation's own `queryItems = []`
        // behavior (an empty query string) — nothing to rewrite.
        components.setQueryItemsEncodingPlus([])
        #expect(components.percentEncodedQuery?.isEmpty ?? true)
    }

    // MARK: - Helpers

    private static func stubListResponse(_ capture: CaptureBox<URLRequest>) {
        MockURLProtocol.setHandler(forHost: apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["requests": [], "total": 0]))
        }
    }

    private static func makePlusTestClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(apiHost)")!)
    }

    private static func makePlusTestDigestClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(digestHost)")!)
    }
}

// MARK: - Shared raw-query helpers (file-private)

/// Query items decoded back through Foundation (`%2B` and `+` both read `+`).
private func decodedQueryItems(of request: URLRequest) -> [String: String] {
    guard let url = request.url,
          let items = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems
    else { return [:] }
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
}
