import Foundation
import Testing
@testable import CupThreadFeedback

// All network tests share the static MockURLProtocol handler, so they run serialized.
// This suite uses its own base host so it can run in parallel with the other suites.
@Suite("CommentPagination", .serialized)
struct CommentPaginationTests {
    static let apiHost = "comment-pages.example.com"

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
        private(set) var requestedLimits: [String] = []

        init(pages: [(HTTPURLResponse, Data)]) {
            self.pages = pages
        }

        func respond(to request: URLRequest) throws -> (HTTPURLResponse, Data) {
            lock.lock()
            defer { lock.unlock() }
            let query = queryItems(of: request)
            requestedCursors.append(query["cursor"])
            requestedLimits.append(query["limit"] ?? "")
            let index = min(pages.count - 1, requestedCursors.count - 1)
            return pages[index]
        }

    }

    // MARK: - Single page fetch

    @Test func fetchCommentPageSendsLimitQueryWithoutCursor() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["comments": []]))
        }

        _ = try await Self.makePagedClient().fetchComments(featureRequestId: "fr-123", limit: 200)

        let request = try #require(capture.value)
        #expect(request.url?.path == "/api/v1/feature-requests/fr-123/comments")
        #expect(request.httpMethod == "GET")
        #expect(queryItems(of: request)["limit"] == "200")
        #expect(request.url?.query?.contains("cursor=") == false)
        #expect(request.value(forHTTPHeaderField: "X-SDK-Version") == FeedbackClient.sdkVersion)
        #expect(request.value(forHTTPHeaderField: "X-Request-Id") != nil)
    }

    @Test func fetchCommentPageSendsCustomLimitAndCursor() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["comments": []]))
        }

        _ = try await Self.makePagedClient().fetchComments(
            featureRequestId: "fr-123",
            limit: 20,
            cursor: "MjAyNi0w"
        )

        let request = try #require(capture.value)
        #expect(queryItems(of: request)["limit"] == "20")
        #expect(queryItems(of: request)["cursor"] == "MjAyNi0w")
    }

    @Test func fetchCommentPageDecodesTotalSeparatelyFromPageLength() async throws {
        // `total` is the visible thread size. A page of one row must not be
        // treated as a one-comment thread.
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            commentPage(
                comments: [makeCommentJSON(id: "c-1")],
                total: 501,
                hasMore: true,
                nextCursor: "MjAyNi0w"
            )
        }

        let result = try await Self.makePagedClient().fetchComments(featureRequestId: "fr-1", limit: 200)

        #expect(result.comments.map(\.id) == ["c-1"])
        #expect(result.total == 501)
        #expect(result.hasMore == true)
        #expect(result.nextCursor == "MjAyNi0w")
    }

    @Test func fetchCommentPageDoesNotFollowNextCursor() async throws {
        let script = PageScript(pages: [
            commentPage(
                comments: [makeCommentJSON(id: "c-1")],
                total: 2,
                hasMore: true,
                nextCursor: "c1"
            ),
            commentPage(
                comments: [makeCommentJSON(id: "c-2")],
                total: 2,
                hasMore: false,
                nextCursor: nil
            )
        ])
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            try script.respond(to: request)
        }

        let result = try await Self.makePagedClient().fetchComments(featureRequestId: "fr-1", limit: 1)

        #expect(script.requestedCursors == [nil])
        #expect(result.comments.map(\.id) == ["c-1"])
        #expect(result.hasMore == true)
        #expect(result.nextCursor == "c1")
    }

    @Test func fetchCommentPageLenientlyDecodesLegacyBodyWithoutPaginationKeys() async throws {
        // Bodies published before cursor pagination shipped must keep
        // decoding as a single complete page.
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(), try encodeJSON([
                "comments": [makeCommentJSON(id: "c-1")]
            ]))
        }

        let result = try await Self.makePagedClient().fetchComments(featureRequestId: "fr-1", limit: 200)

        #expect(result.comments.map(\.id) == ["c-1"])
        #expect(result.total == 0)
        #expect(result.hasMore == false)
        #expect(result.nextCursor == nil)
    }

    @Test func fetchCommentPageSurfaces400ForInvalidCursor() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 400), try encodeJSON(["error": "Invalid cursor"]))
        }

        do {
            _ = try await Self.makePagedClient().fetchComments(
                featureRequestId: "fr-1",
                limit: 200,
                cursor: "not-a-cursor"
            )
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            if case .unexpectedStatus(let code, _, _) = error {
                #expect(code == 400)
            } else {
                Issue.record("Unexpected error type: \(error)")
            }
        }
    }

    // MARK: - Full-thread walker

    @Test func fetchCommentsWalksCursorPagesInServerOrderUntilLastPage() async throws {
        // Oldest-first keyset order must be preserved. Re-sorting newest-first
        // (the changelog walk does that) would yield c2, c3, c1.
        let script = PageScript(pages: [
            commentPage(
                comments: [
                    makeCommentJSON(id: "c-1", createdAt: "2026-01-01T00:00:00.000Z"),
                    makeCommentJSON(id: "c-2", createdAt: "2026-03-01T00:00:00.000Z")
                ],
                total: 3,
                hasMore: true,
                nextCursor: "c1"
            ),
            commentPage(
                comments: [
                    makeCommentJSON(id: "c-3", createdAt: "2026-02-01T00:00:00.000Z")
                ],
                total: 3,
                hasMore: false,
                nextCursor: nil
            )
        ])
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            try script.respond(to: request)
        }

        let comments = try await Self.makePagedClient().fetchComments(featureRequestId: "fr-1")

        #expect(script.requestedCursors == [nil, "c1"])
        #expect(script.requestedLimits == ["200", "200"])
        #expect(comments.map(\.id) == ["c-1", "c-2", "c-3"])
    }

    @Test func fetchCommentsDeduplicatesOverlappingCursorPages() async throws {
        let script = PageScript(pages: [
            commentPage(
                comments: [
                    makeCommentJSON(id: "c-1"),
                    makeCommentJSON(id: "c-2")
                ],
                total: 3,
                hasMore: true,
                nextCursor: "c1"
            ),
            commentPage(
                comments: [
                    makeCommentJSON(id: "c-2"),
                    makeCommentJSON(id: "c-3")
                ],
                total: 3,
                hasMore: false,
                nextCursor: nil
            )
        ])
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            try script.respond(to: request)
        }

        let comments = try await Self.makePagedClient().fetchComments(featureRequestId: "fr-1")

        #expect(script.requestedCursors == [nil, "c1"])
        #expect(comments.map(\.id) == ["c-1", "c-2", "c-3"])
    }

    @Test func fetchCommentsStopsWhenCollectedCountReachesTotal() async throws {
        // `total` is the thread size. A server that keeps advertising
        // `hasMore` after the visible thread is already in hand must not
        // be followed — and the extra page must not extend the result.
        let script = PageScript(pages: [
            commentPage(
                comments: [
                    makeCommentJSON(id: "c-1"),
                    makeCommentJSON(id: "c-2")
                ],
                total: 2,
                hasMore: true,
                nextCursor: "c1"
            ),
            commentPage(
                comments: [makeCommentJSON(id: "c-3")],
                total: 2,
                hasMore: false,
                nextCursor: nil
            )
        ])
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            try script.respond(to: request)
        }

        let comments = try await Self.makePagedClient().fetchComments(featureRequestId: "fr-1")

        #expect(script.requestedCursors == [nil])
        #expect(comments.map(\.id) == ["c-1", "c-2"])
    }

    @Test func fetchCommentsStopsWhenServerReplaysTheSamePage() async throws {
        let script = PageScript(pages: [
            commentPage(
                comments: [
                    makeCommentJSON(id: "c-1"),
                    makeCommentJSON(id: "c-2")
                ],
                total: 50,
                hasMore: true,
                nextCursor: "c1"
            )
        ])
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            try script.respond(to: request)
        }

        let comments = try await Self.makePagedClient().fetchComments(featureRequestId: "fr-1")

        #expect(script.requestedCursors == [nil, "c1"])
        #expect(comments.map(\.id) == ["c-1", "c-2"])
    }

    @Test func fetchCommentsStopsWhenHasMoreHasNoCursor() async throws {
        let script = PageScript(pages: [
            commentPage(
                comments: [makeCommentJSON(id: "c-1")],
                total: 50,
                hasMore: true,
                nextCursor: nil
            )
        ])
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            try script.respond(to: request)
        }

        let comments = try await Self.makePagedClient().fetchComments(featureRequestId: "fr-1")

        #expect(script.requestedCursors == [nil])
        #expect(comments.map(\.id) == ["c-1"])
    }

    @Test func fetchCommentsReadsLegacySinglePayloadAsTheWholeThread() async throws {
        let script = PageScript(pages: [
            (makeHTTPResponse(), try encodeJSON([
                "comments": [makeCommentJSON(id: "c-1")]
            ]))
        ])
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            try script.respond(to: request)
        }

        let comments = try await Self.makePagedClient().fetchComments(featureRequestId: "fr-1")

        #expect(script.requestedCursors == [nil])
        #expect(comments.map(\.id) == ["c-1"])
    }

    @Test func fetchCommentsThrowsWhenALaterPageFails() async throws {
        let script = PageScript(pages: [
            commentPage(
                comments: [makeCommentJSON(id: "c-1")],
                total: 2,
                hasMore: true,
                nextCursor: "c1"
            ),
            (makeHTTPResponse(status: 400), try encodeJSON(["error": "Invalid cursor"]))
        ])
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            try script.respond(to: request)
        }

        do {
            _ = try await Self.makePagedClient().fetchComments(featureRequestId: "fr-1")
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            if case .unexpectedStatus(let code, _, _) = error {
                #expect(code == 400)
            } else {
                Issue.record("Unexpected error type: \(error)")
            }
        }
        #expect(script.requestedCursors == [nil, "c1"])
    }
}

// MARK: - JSON fixtures

private func queryItems(of request: URLRequest) -> [String: String] {
    guard let url = request.url,
          let items = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems
    else { return [:] }
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
}

private func makeCommentJSON(
    id: String,
    createdAt: String = "2026-01-01T00:00:00.000Z"
) -> [String: Any] {
    [
        "id": id,
        "featureRequestId": "fr-1",
        "body": "Comment \(id)",
        "createdAt": createdAt
    ]
}

private func commentPage(
    comments: [[String: Any]],
    total: Int,
    hasMore: Bool,
    nextCursor: String?
) -> (HTTPURLResponse, Data) {
    var payload: [String: Any] = [
        "comments": comments,
        "total": total,
        "hasMore": hasMore
    ]
    payload["nextCursor"] = nextCursor ?? NSNull()
    return (makeHTTPResponse(), (try? encodeJSON(payload)) ?? Data())
}
