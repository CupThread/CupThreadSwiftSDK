import Foundation
import Testing
@testable import CupThreadFeedback

// All network tests share the static MockURLProtocol handler, so they run serialized.
// This suite uses its own base host so it can run in parallel with the other suites.
@Suite("ChangelogPagination", .serialized)
struct ChangelogPaginationTests {
    static let apiHost = "changelog-pages.example.com"

    static func makePagedClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(apiHost)")!)
    }

    /// Sequential multi-page responder for cursor-walk tests.
    ///
    /// Records the `cursor` query item of every request and serves the
    /// scripted pages in order; when the script is exhausted the last page
    /// repeats (used by the runaway-guard test).
    private final class PageScript: @unchecked Sendable {
        private let lock = NSLock()
        private var pages: [(HTTPURLResponse, Data)]
        private(set) var requestedCursors: [String?] = []

        init(pages: [(HTTPURLResponse, Data)]) {
            self.pages = pages
        }

        func respond(to request: URLRequest) throws -> (HTTPURLResponse, Data) {
            lock.lock()
            defer { lock.unlock() }
            requestedCursors.append(requestedCursor(of: request))
            let index = min(pages.count - 1, requestedCursors.count - 1)
            return pages[index]
        }

        private func requestedCursor(of request: URLRequest) -> String? {
            guard let url = request.url else { return nil }
            return URLComponents(url: url, resolvingAgainstBaseURL: true)?
                .queryItems?
                .first { $0.name == "cursor" }?
                .value
        }
    }

    // MARK: - Single page fetch

    @Test func fetchChangelogPageSendsLimitQueryWithoutCursor() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["entries": []]))
        }

        _ = try await Self.makePagedClient().fetchChangelog(limit: 50)

        let request = try #require(capture.value)
        #expect(request.url?.path == "/api/v1/public/apps/app_testkey123456/changelog")
        #expect(request.httpMethod == "GET")
        let query = try #require(request.url?.query)
        #expect(queryItems(of: request)["limit"] == "50")
        #expect(query.contains("cursor=") == false)
        #expect(request.value(forHTTPHeaderField: "X-SDK-Version") == FeedbackClient.sdkVersion)
        #expect(request.value(forHTTPHeaderField: "X-Request-Id") != nil)
    }

    @Test func fetchChangelogPageSendsCustomLimitAndCursor() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["entries": []]))
        }

        _ = try await Self.makePagedClient().fetchChangelog(limit: 20, cursor: "MjAyNi0w")

        let request = try #require(capture.value)
        let query = try #require(request.url?.query)
        #expect(query.contains("limit=20"))
        #expect(query.contains("cursor=MjAyNi0w"))
    }

    @Test func fetchChangelogPageDecodesPaginationMetadata() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(), try encodeJSON([
                "entries": [makePagedEntryJSON(id: "cl_1", publishedAt: "2026-09-18T12:00:00.000Z")],
                "hasMore": true,
                "nextCursor": "MjAyNi0w"
            ]))
        }

        let result = try await Self.makePagedClient().fetchChangelog(limit: 50, cursor: nil)

        #expect(result.entries.map(\.id) == ["cl_1"])
        #expect(result.hasMore == true)
        #expect(result.nextCursor == "MjAyNi0w")
    }

    @Test func fetchChangelogPageLenientlyDecodesLegacyBodyWithoutPaginationKeys() async throws {
        // Bodies published before cursor pagination shipped must keep
        // decoding as a single complete page.
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(), try encodeJSON([
                "entries": [makePagedEntryJSON(id: "e1", publishedAt: "2026-01-01T00:00:00.000Z")]
            ]))
        }

        let result = try await Self.makePagedClient().fetchChangelog(limit: 50, cursor: nil)

        #expect(result.entries.map(\.id) == ["e1"])
        #expect(result.hasMore == false)
        #expect(result.nextCursor == nil)
    }

    @Test func fetchChangelogPageMaps401ToAuthenticationRequired() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 401), try encodeJSON(["code": "authentication_required"]))
        }

        do {
            _ = try await Self.makePagedClient().fetchChangelog(limit: 50, cursor: nil)
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            guard case .authenticationRequired = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
        }
    }

    @Test func fetchChangelogPageSurfaces400ForMalformedCursor() async throws {
        // Malformed cursors are rejected server-side with 400 Bad Request.
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 400), try encodeJSON(["error": "Malformed cursor"]))
        }

        do {
            _ = try await Self.makePagedClient().fetchChangelog(cursor: "not-a-cursor")
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            if case .unexpectedStatus(let code, _, _) = error {
                #expect(code == 400)
            } else {
                Issue.record("Unexpected error type: \(error)")
            }
        }
    }

    // MARK: - Full-history walker

    @Test func fetchChangelogWalksCursorPagesUntilServerReportsLastPage() async throws {
        let script = PageScript(pages: [
            page(entries: [
                makePagedEntryJSON(id: "e1", publishedAt: "2026-01-01T00:00:00.000Z"),
                makePagedEntryJSON(id: "e2", publishedAt: "2026-03-01T00:00:00.000Z")
            ], hasMore: true, nextCursor: "c1"),
            page(entries: [
                makePagedEntryJSON(id: "e3", publishedAt: "2026-02-01T00:00:00.000Z")
            ], hasMore: false, nextCursor: nil)
        ])
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            try script.respond(to: request)
        }

        let entries = try await Self.makePagedClient().fetchChangelog()

        #expect(script.requestedCursors == [nil, "c1"])
        #expect(entries.map(\.id) == ["e2", "e3", "e1"])
    }

    @Test func fetchChangelogDeduplicatesOverlappingCursorPages() async throws {
        let script = PageScript(pages: [
            page(entries: [
                makePagedEntryJSON(id: "e1", publishedAt: "2026-02-01T00:00:00.000Z"),
                makePagedEntryJSON(id: "e2", publishedAt: "2026-01-01T00:00:00.000Z")
            ], hasMore: true, nextCursor: "c1"),
            page(entries: [
                makePagedEntryJSON(id: "e2", publishedAt: "2026-01-01T00:00:00.000Z"),
                makePagedEntryJSON(id: "e3", publishedAt: "2025-12-01T00:00:00.000Z")
            ], hasMore: false, nextCursor: nil)
        ])
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            try script.respond(to: request)
        }

        let entries = try await Self.makePagedClient().fetchChangelog()

        #expect(script.requestedCursors == [nil, "c1"])
        #expect(entries.map(\.id) == ["e1", "e2", "e3"])
    }

    @Test func fetchChangelogStopsWhenServerReplaysTheSamePage() async throws {
        // A misbehaving backend that keeps reporting hasMore while replaying
        // the same entries must not hang the walk.
        let script = PageScript(pages: [
            page(entries: [
                makePagedEntryJSON(id: "e1", publishedAt: "2026-01-01T00:00:00.000Z"),
                makePagedEntryJSON(id: "e2", publishedAt: "2026-02-01T00:00:00.000Z")
            ], hasMore: true, nextCursor: "c1")
        ])
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            try script.respond(to: request)
        }

        let entries = try await Self.makePagedClient().fetchChangelog()

        #expect(script.requestedCursors == [nil, "c1"])
        #expect(entries.map(\.id) == ["e2", "e1"])
    }
}

// MARK: - JSON fixtures

private func queryItems(of request: URLRequest) -> [String: String] {
    guard let url = request.url,
          let items = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems
    else { return [:] }
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
}

private func makePagedEntryJSON(id: String, publishedAt: String) -> [String: Any] {
    [
        "id": id,
        "title": "Entry \(id)",
        "body": "Improvements and fixes.",
        "versionLabel": NSNull(),
        "publishedAt": publishedAt,
        "linkedRequests": [] as [[String: String]]
    ]
}

private func page(
    entries: [[String: Any]],
    hasMore: Bool,
    nextCursor: String?
) -> (HTTPURLResponse, Data) {
    var payload: [String: Any] = ["entries": entries, "hasMore": hasMore]
    payload["nextCursor"] = nextCursor ?? NSNull()
    return (makeHTTPResponse(), (try? encodeJSON(payload)) ?? Data())
}
