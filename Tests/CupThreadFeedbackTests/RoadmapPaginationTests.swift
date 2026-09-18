import Foundation
import Testing
@testable import CupThreadFeedback

/// Tests for the complete-data pagination loop that backs the roadmap board:
/// multi-page cursor walks, termination, dedupe, and failure propagation.
@Suite("RoadmapPagination")
struct RoadmapPaginationTests {
    // MARK: Fixtures

    private func makeItem(
        _ id: String,
        voteCount: Int = 1,
        hasVoted: Bool = false
    ) -> FeatureRequestItem {
        FeatureRequestItem(
            id: id,
            appId: "app-1",
            title: "Request \(id)",
            description: "Description \(id)",
            status: "backlog",
            columnId: "col-1",
            columnSlug: "backlog",
            columnName: "Backlog",
            versionId: nil,
            versionLabel: nil,
            releasedVersion: nil,
            requesterName: "Requester",
            requesterAvatarUrl: nil,
            requesterClerkId: nil,
            recentCommenters: [],
            hasMoreCommenters: false,
            approved: true,
            voteCount: voteCount,
            hasVoted: hasVoted,
            isOwnRequest: false,
            createdAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-01-01T00:00:00.000Z"
        )
    }

    private func makePage(
        _ ids: [String],
        total: Int = 0,
        hasMore: Bool = false,
        nextCursor: String? = nil
    ) -> ListFeatureRequestsResult {
        ListFeatureRequestsResult(
            requests: ids.map { makeItem($0) },
            total: total,
            hasMore: hasMore,
            nextCursor: nextCursor
        )
    }

    /// Records the cursors the loop asked for and replays a scripted page
    /// sequence (or throws) in order.
    private final class PageScript: @unchecked Sendable {
        private let lock = NSLock()
        private var pages: [Result<ListFeatureRequestsResult, Error>]
        private(set) var requestedCursors: [String?] = []

        init(_ pages: [Result<ListFeatureRequestsResult, Error>]) {
            self.pages = pages
        }

        init(_ pages: [ListFeatureRequestsResult]) {
            self.pages = pages.map { .success($0) }
        }

        func next(_ cursor: String?) throws -> ListFeatureRequestsResult {
            lock.lock()
            defer { lock.unlock() }
            requestedCursors.append(cursor)
            guard !pages.isEmpty else {
                throw TestScriptError.exhausted
            }
            return try pages.removeFirst().get()
        }
    }

    private enum TestScriptError: Error {
        case exhausted
    }

    // MARK: Cursor walk

    @Test func walksCursorPagesUntilServerReportsLastPage() async throws {
        // 120 matching requests, three 50/50/20 pages — more than one page
        // size, so a single-page board would have been truncated.
        let script = PageScript([
            makePage((1...50).map { "fr-\($0)" }, total: 120, hasMore: true, nextCursor: "c1"),
            makePage((51...100).map { "fr-\($0)" }, total: 120, hasMore: true, nextCursor: "c2"),
            makePage((101...120).map { "fr-\($0)" }, total: 120, hasMore: false)
        ])

        let collected = try await collectAllRequests { cursor in
            try script.next(cursor)
        }

        #expect(collected.count == 120)
        #expect(collected.first?.id == "fr-1")
        #expect(collected.last?.id == "fr-120")
        #expect(script.requestedCursors == [nil, "c1", "c2"])
    }

    @Test func stopsOnceCollectedCountReachesReportedTotal() async throws {
        // The server still advertises a cursor although everything was
        // delivered — the reported total is the authoritative end.
        let script = PageScript([
            makePage((1...50).map { "fr-\($0)" }, total: 50, hasMore: true, nextCursor: "c1")
        ])

        let collected = try await collectAllRequests { cursor in
            try script.next(cursor)
        }

        #expect(collected.count == 50)
        #expect(script.requestedCursors == [nil])
    }

    @Test func followsCursorsWhenServerOmitsTotal() async throws {
        // `total` decodes as 0 when omitted; the cursor chain alone decides
        // when to stop.
        let script = PageScript([
            makePage((1...50).map { "fr-\($0)" }, hasMore: true, nextCursor: "c1"),
            makePage((51...80).map { "fr-\($0)" }, hasMore: false)
        ])

        let collected = try await collectAllRequests { cursor in
            try script.next(cursor)
        }

        #expect(collected.count == 80)
        #expect(script.requestedCursors == [nil, "c1"])
    }

    // MARK: Dedupe and termination safety

    @Test func skipsDuplicateIDsAcrossOverlappingPages() async throws {
        let script = PageScript([
            makePage(["fr-1", "fr-2", "fr-3"], hasMore: true, nextCursor: "c1"),
            makePage(["fr-2", "fr-3", "fr-4"], hasMore: false)
        ])

        let collected = try await collectAllRequests { cursor in
            try script.next(cursor)
        }

        #expect(collected.map(\.id) == ["fr-1", "fr-2", "fr-3", "fr-4"])
    }

    @Test func stopsWhenPageYieldsNoNewIDs() async throws {
        // A backend that keeps replaying the same page and cursor must not
        // hang the board — the second page adds nothing, so the walk ends.
        let script = PageScript([
            makePage(["fr-1", "fr-2", "fr-3"], hasMore: true, nextCursor: "c1"),
            makePage(["fr-1", "fr-2", "fr-3"], hasMore: true, nextCursor: "c1")
        ])

        let collected = try await collectAllRequests { cursor in
            try script.next(cursor)
        }

        #expect(collected.map(\.id) == ["fr-1", "fr-2", "fr-3"])
        #expect(script.requestedCursors == [nil, "c1"])
    }

    @Test func emptyPageStopsTheWalkEvenWhenACursorIsOffered() async throws {
        let script = PageScript([
            makePage([], hasMore: true, nextCursor: "c1")
        ])

        let collected = try await collectAllRequests { cursor in
            try script.next(cursor)
        }

        #expect(collected.isEmpty)
        #expect(script.requestedCursors == [nil])
    }

    // MARK: Failure propagation

    @Test func secondPageFailurePropagates() async {
        let script = PageScript([
            .success(makePage(["fr-1"], hasMore: true, nextCursor: "c1")),
            .failure(FeedbackClientError.invalidResponse)
        ])

        await #expect(throws: FeedbackClientError.self) {
            try await collectAllRequests { cursor in
                try script.next(cursor)
            }
        }
        #expect(script.requestedCursors == [nil, "c1"])
    }

    @Test func cancellationBetweenPagesPropagates() async {
        let script = PageScript([
            .success(makePage(["fr-1"], hasMore: true, nextCursor: "c1")),
            .failure(CancellationError())
        ])

        await #expect(throws: CancellationError.self) {
            try await collectAllRequests { cursor in
                try script.next(cursor)
            }
        }
    }
}
