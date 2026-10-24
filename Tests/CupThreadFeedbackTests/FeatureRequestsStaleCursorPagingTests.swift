import Foundation
import SwiftUI
import Testing
@testable import CupThreadFeedback

/// BUG-45 (issue #557): `loadNextPage` used to pair the cursor minted by the
/// last *successful* replacing load with the view's *current* filter. A failed
/// replacing search (or version switch) preserves the rendered page — its
/// cursor included — so the next "Load more" tap (or the near-end auto-pager)
/// silently sent `q=abc` with the unfiltered listing's cursor, appending
/// unfiltered page rows under an active search and making every earlier `abc`
/// match unreachable until a replacing search finally succeeded.
///
/// Two layers pin the fix:
///
/// - `loadNextPage` refuses to page while `listState.lastExecutedFilterKey`
///   differs from the view's current filter key — the pending replacing load
///   (retry or the successful `.task(id: filterKey)` rerun) is the path to a
///   matching list.
/// - a failed replacing load retires the cursor (`invalidatePagination`) so
///   the load-more affordance disappears with it. Cancellation never reaches
///   that path: `SearchReloadOutcome` returns `nil` for a cancellation error
///   (unit-pinned in `SearchReloadOutcomeTests`), preserving the #59/#545
///   content-preservation contract.
///
/// The stub's request log is the observable: a view outside a SwiftUI
/// hierarchy cannot persist `@State` writes (see the test-support hooks on
/// `FeatureRequestsView`).
@Suite("FeatureRequestsView Stale Cursor Paging", .serialized)
struct FeatureRequestsStaleCursorPagingTests {
    static let apiHost = "stale-cursor-paging.example.com"

    /// The view's private `filterKey` format for this suite's config
    /// (anonymous roadmap permitted, no version filter).
    static let unfilteredFilterKey = "features|true||"

    // MARK: - Helpers

    /// Thread-safe request log; the URLProtocol handler runs off the test actor.
    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [String] = []
        func record(url: String?) {
            lock.lock()
            defer { lock.unlock() }
            requests.append(url ?? "")
        }
        var urls: [String] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }
    }

    private func makeConfig() -> PublicAppConfig {
        PublicAppConfig(
            appId: "app-1",
            appKey: "app_testkey123456",
            slug: "demo",
            name: "Demo",
            allowPublic: true,
            allowedPlatforms: nil,
            allowedPlatformValues: [],
            allowAnonymousRoadmap: true,
            allowAnonymousVote: true,
            allowAnonymousFeedback: true,
            allowAnonymousChangelog: true
        )
    }

    @MainActor
    private func makeView(
        listState: FeatureRequestsListState,
        initialSearchText: String
    ) -> FeatureRequestsView {
        FeatureRequestsView(
            client: makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!),
            userToken: "tok",
            listState: listState,
            configOverride: makeConfig(),
            initialSearchText: initialSearchText
        )
    }

    private static func makeItemJSON(id: String) -> [String: Any] {
        [
            "id": id,
            "appId": "app-1",
            "title": "Request \(id)",
            "description": "Desc",
            "status": "in_progress",
            "approved": true,
            "voteCount": 3,
            "hasVoted": false,
            "isOwnRequest": false,
            "createdAt": "2026-01-01T00:00:00Z",
            "updatedAt": "2026-01-02T00:00:00Z"
        ]
    }

    private func makeItem(id: String) -> FeatureRequestItem {
        FeatureRequestItem(
            id: id,
            appId: "app-1",
            title: "Request \(id)",
            description: "Desc",
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
            voteCount: 5,
            hasVoted: false,
            isOwnRequest: false,
            createdAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-01-01T00:00:00.000Z"
        )
    }

    private func makePageResult(
        requests: [FeatureRequestItem],
        hasMore: Bool,
        nextCursor: String?
    ) -> ListFeatureRequestsResult {
        ListFeatureRequestsResult(requests: requests, total: 60, hasMore: hasMore, nextCursor: nextCursor)
    }

    /// A page-1 state minted by `executedFilterKey` with paging still open —
    /// the shape a successful unfiltered load leaves behind.
    private func makePagingState(cursor: String, executedFilterKey: String) -> FeatureRequestsListState {
        var state = FeatureRequestsListState()
        state.applyPage(
            makePageResult(requests: [makeItem(id: "fr-1")], hasMore: true, nextCursor: cursor),
            replacesExisting: true,
            executedFilterKey: executedFilterKey
        )
        return state
    }

    /// Records every request to the suite's host; `/feature-requests` answers
    /// 500 when `returningServerError` is set, otherwise page 1 (more pages
    /// available) and the `cursor=page-2` follow-up (last page).
    private func stubFeatureRequestsPage(returningServerError: Bool) -> RequestLog {
        let log = RequestLog()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            log.record(url: request.url?.absoluteString)
            guard request.url?.path.hasSuffix("/feature-requests") == true else {
                return (makeHTTPResponse(), try encodeJSON([:]))
            }
            if returningServerError {
                return (makeHTTPResponse(status: 500), try encodeJSON(["error": "boom"]))
            }
            if request.url?.query?.contains("cursor=page-2") == true {
                return (makeHTTPResponse(), try encodeJSON([
                    "requests": [Self.makeItemJSON(id: "fr-2")], "total": 60, "hasMore": false
                ]))
            }
            return (makeHTTPResponse(), try encodeJSON([
                "requests": [Self.makeItemJSON(id: "fr-1")],
                "total": 60,
                "hasMore": true,
                "nextCursor": "page-2"
            ]))
        }
        return log
    }

    // MARK: - The stale-cursor trap (BUG-45, issue #557)

    @Test @MainActor func pagingIsRefusedWhileTheCursorBelongsToAnotherFilter() async {
        let log = stubFeatureRequestsPage(returningServerError: false)
        // Page 1 was minted by the unfiltered listing; the view now carries an
        // active search whose replacing load is still pending (or failed).
        let view = makeView(
            listState: makePagingState(cursor: "stale-c1", executedFilterKey: Self.unfilteredFilterKey),
            initialSearchText: "abc"
        )

        await view.loadNextPageForTesting()

        #expect(
            log.urls.isEmpty,
            "paging must never pair the current filter with the previous filter's cursor"
        )
    }

    @Test @MainActor func pagingAfterAFailedReplacingSearchNeverPairsTheNewQueryWithTheOldCursor() async {
        let log = stubFeatureRequestsPage(returningServerError: true)
        let view = makeView(
            listState: makePagingState(cursor: "stale-c1", executedFilterKey: Self.unfilteredFilterKey),
            initialSearchText: "abc"
        )

        // The replacing search fails transiently; the rendered page (and its
        // cursor) is preserved by the #59/#545 contract...
        await view.loadFeatureRequestsForTesting()
        // ...but "Load more" (or the near-end auto-pager) must not extend the
        // stale page under the new filter.
        await view.loadNextPageForTesting()

        let listRequests = log.urls.filter { $0.contains("/feature-requests") }
        #expect(listRequests.count == 1, "only the failing replacing load may reach the endpoint")
        #expect(listRequests.first?.contains("q=abc") == true)
        #expect(
            listRequests.first?.contains("cursor=") != true,
            "the failed search's request must not be followed by one carrying the old cursor"
        )
    }

    // MARK: - Positive regression: matching filter still pages

    @Test @MainActor func pagingAfterASuccessfulReplacingLoadStillAppendsTheCursorPage() async {
        let log = stubFeatureRequestsPage(returningServerError: false)
        // Page 1 and the view's filter agree — paging appends as before.
        let view = makeView(
            listState: makePagingState(cursor: "page-2", executedFilterKey: Self.unfilteredFilterKey),
            initialSearchText: ""
        )

        await view.loadNextPageForTesting()

        let pagingRequests = log.urls.filter { $0.contains("cursor=") }
        #expect(pagingRequests.count == 1)
        #expect(pagingRequests.first?.contains("cursor=page-2") == true)
        #expect(
            pagingRequests.first?.contains("q=") != true,
            "an empty search must not ride the paging request"
        )
    }
}
