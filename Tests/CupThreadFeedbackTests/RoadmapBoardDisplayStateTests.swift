import Foundation
import Testing
@testable import CupThreadFeedback

@Suite("RoadmapBoardDisplayState")
struct RoadmapBoardDisplayStateTests {
    private func makeColumn(id: String, name: String) -> BoardColumn {
        BoardColumn(
            id: id,
            appId: "app-1",
            name: name,
            slug: "slug-\(id)",
            position: 0,
            isVisible: true,
            isSystem: false,
            kind: .normal,
            createdAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-01-01T00:00:00.000Z"
        )
    }

    private func makeItem(id: String, columnId: String?) -> FeatureRequestItem {
        FeatureRequestItem(
            id: id,
            appId: "app-1",
            title: "Test Request \(id)",
            description: "Description for \(id)",
            status: columnId ?? "none",
            columnId: columnId,
            columnSlug: columnId.map { "slug-\($0)" },
            columnName: columnId.map { "Name-\($0)" },
            versionId: nil,
            versionLabel: nil,
            releasedVersion: nil,
            requesterName: "Requester",
            requesterAvatarUrl: nil,
            requesterClerkId: nil,
            recentCommenters: [],
            hasMoreCommenters: false,
            approved: true,
            voteCount: 1,
            hasVoted: false,
            isOwnRequest: false,
            createdAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-01-01T00:00:00.000Z"
        )
    }

    private func makeState(
        isLoading: Bool = false,
        hasLoadedOnce: Bool = true,
        loadError: String? = nil,
        searchText: String = "",
        groups: [RoadmapGroup]
    ) -> RoadmapBoardDisplayState {
        makeBoardDisplayState(
            isLoading: isLoading,
            hasLoadedOnce: hasLoadedOnce,
            loadError: loadError,
            searchText: searchText,
            groups: groups
        )
    }

    @Test func firstLoadInProgressYieldsLoadingEvenWithStaleInputs() {
        let columns = [makeColumn(id: "col-1", name: "Planned")]
        let groups = makeGroups(columns: columns, requests: [makeItem(id: "req-1", columnId: "col-1")])

        let state = makeState(
            isLoading: true,
            hasLoadedOnce: false,
            loadError: "stale error",
            groups: groups
        )

        #expect(state == .loading)
    }

    @Test func loadErrorYieldsErrorRegardlessOfGroups() {
        let groups = makeGroups(columns: [makeColumn(id: "col-1", name: "Planned")], requests: [])

        #expect(makeState(loadError: "Network unreachable", groups: groups) == .error("Network unreachable"))
        #expect(makeState(loadError: "Network unreachable", groups: []) == .error("Network unreachable"))
    }

    @Test func zeroMatchSearchWithPublishedColumnsYieldsEmptySearch() {
        // Zero-match search: columns exist (groups non-empty) but every group
        // lost its requests to the server-side query — the pre-fix layouts
        // fell through to an empty ForEach and rendered a blank board here.
        let columns = [
            makeColumn(id: "col-1", name: "Planned"),
            makeColumn(id: "col-2", name: "Shipped")
        ]
        let groups = makeGroups(columns: columns, requests: [])

        let state = makeState(searchText: "nonexistent widget", groups: groups)

        #expect(state == .emptySearch(query: "nonexistent widget"))
    }

    @Test func emptySearchTextWithNoColumnsYieldsEmptyBoard() {
        #expect(makeState(searchText: "", groups: []) == .emptyBoard)
    }

    @Test func plainListingWithColumnsYieldsUnfilteredBoard() {
        let columns = [
            makeColumn(id: "col-1", name: "Planned"),
            makeColumn(id: "col-2", name: "Shipped")
        ]
        let planned = makeItem(id: "req-1", columnId: "col-1")
        let groups = makeGroups(columns: columns, requests: [planned])

        let state = makeState(searchText: "", groups: groups)

        #expect(state == .board(groups))
        if case let .board(visibleGroups) = state {
            #expect(visibleGroups.count == 2)
            #expect(visibleGroups[0].requests == [planned])
            #expect(visibleGroups[1].requests.isEmpty)
        }
    }

    @Test func matchingSearchFiltersOutEmptyColumns() {
        let columns = [
            makeColumn(id: "col-1", name: "Planned"),
            makeColumn(id: "col-2", name: "Shipped")
        ]
        let matching = makeItem(id: "req-1", columnId: "col-2")
        let groups = makeGroups(columns: columns, requests: [matching])

        let state = makeState(searchText: "Test Request req-1", groups: groups)

        if case let .board(visibleGroups) = state {
            #expect(visibleGroups.count == 1)
            #expect(visibleGroups[0].id == "col-2")
            #expect(visibleGroups[0].requests == [matching])
        } else {
            Issue.record("Expected .board, got \(state)")
        }
    }

    @Test func reloadInProgressKeepsPriorContentVisible() {
        // A search-driven reload sets isLoading without resetting hasLoadedOnce,
        // and load() clears loadError at the start — the previous board must
        // stay on screen instead of flashing skeletons or an error.
        let columns = [makeColumn(id: "col-1", name: "Planned")]
        let groups = makeGroups(columns: columns, requests: [makeItem(id: "req-1", columnId: "col-1")])

        let state = makeState(isLoading: true, hasLoadedOnce: true, groups: groups)

        #expect(state == .board(groups))
    }

    @Test func makeGroupsWithAllEmptyRequestsAndActiveSearchYieldsZeroVisibleGroups() {
        // Regression guard: makeGroups always emits one group per column, so a
        // zero-match search leaves `groups` non-empty while `visibleGroups` is
        // empty. Deriving visibility from `groups.isEmpty` instead of the
        // search filter reintroduces the blank-board bug (#33).
        let columns = [
            makeColumn(id: "col-1", name: "Planned"),
            makeColumn(id: "col-2", name: "Shipped")
        ]
        let groups = makeGroups(columns: columns, requests: [])
        #expect(groups.count == 2)

        let state = makeState(searchText: "nothing matches this", groups: groups)

        // If the filter were dropped, this would come back as .board(groups)
        // with two request-less columns instead of the empty-search state.
        #expect(state == .emptySearch(query: "nothing matches this"))
    }
}
