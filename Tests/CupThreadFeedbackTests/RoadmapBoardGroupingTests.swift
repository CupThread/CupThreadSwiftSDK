import Foundation
import Testing
@testable import CupThreadFeedback

@Suite("RoadmapBoardGrouping")
struct RoadmapBoardGroupingTests {
    private func makeItem(
        id: String,
        columnId: String? = "col-1",
        title: String = "Test Request"
    ) -> FeatureRequestItem {
        FeatureRequestItem(
            id: id,
            appId: "app-1",
            title: title,
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

    private func makeColumn(
        id: String,
        name: String,
        slug: String = "slug",
        position: Int = 0,
        kind: BoardColumn.Kind = .normal
    ) -> BoardColumn {
        BoardColumn(
            id: id,
            appId: "app-1",
            name: name,
            slug: slug,
            position: position,
            isVisible: true,
            isSystem: false,
            kind: kind,
            createdAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-01-01T00:00:00.000Z"
        )
    }

    @Test func requestsWithNilColumnLandInOtherGroup() {
        let columns = [
            makeColumn(id: "col-1", name: "In Progress"),
            makeColumn(id: "col-2", name: "Completed")
        ]
        let item1 = makeItem(id: "req-1", columnId: "col-1")
        let item2 = makeItem(id: "req-2", columnId: nil)
        let item3 = makeItem(id: "req-3", columnId: "col-2")

        let groups = makeGroups(columns: columns, requests: [item1, item2, item3])

        #expect(groups.count == 3)
        #expect(groups[0].column?.id == "col-1")
        #expect(groups[0].requests == [item1])
        #expect(groups[1].column?.id == "col-2")
        #expect(groups[1].requests == [item3])

        #expect(groups[2].column == nil)
        #expect(groups[2].id == "uncategorized")
        #expect(groups[2].name == CupThreadStrings.tr("cupthread.roadmap.column_other"))
        #expect(groups[2].requests == [item2])
    }

    @Test func requestsWithHiddenOrDeletedColumnLandInOtherGroup() {
        let columns = [
            makeColumn(id: "col-1", name: "Planned"),
            makeColumn(id: "col-2", name: "In Progress")
        ]
        let item1 = makeItem(id: "req-1", columnId: "col-1")
        let itemHidden = makeItem(id: "req-hidden", columnId: "col-internal-triage")
        let itemDeleted = makeItem(id: "req-deleted", columnId: "col-deleted")

        let groups = makeGroups(columns: columns, requests: [item1, itemHidden, itemDeleted])

        #expect(groups.count == 3)
        #expect(groups[0].column?.id == "col-1")
        #expect(groups[0].requests == [item1])
        #expect(groups[1].column?.id == "col-2")
        #expect(groups[1].requests.isEmpty)

        #expect(groups[2].column == nil)
        #expect(groups[2].id == "uncategorized")
        #expect(groups[2].requests == [itemHidden, itemDeleted])
    }

    @Test func requestsMatchingVisibleColumnsGroupInServerOrderWithoutOtherGroup() {
        let columns = [
            makeColumn(id: "col-1", name: "Backlog"),
            makeColumn(id: "col-2", name: "Shipped")
        ]
        let item1 = makeItem(id: "req-1", columnId: "col-1")
        let item2 = makeItem(id: "req-2", columnId: "col-2")
        let item3 = makeItem(id: "req-3", columnId: "col-1")
        let item4 = makeItem(id: "req-4", columnId: "col-2")

        let groups = makeGroups(columns: columns, requests: [item1, item2, item3, item4])

        #expect(groups.count == 2)
        #expect(groups[0].column?.id == "col-1")
        #expect(groups[0].requests == [item1, item3])
        #expect(groups[1].column?.id == "col-2")
        #expect(groups[1].requests == [item2, item4])
    }

    @Test func mixedInputPreservesAllRequestsAndMaintainsInvariant() {
        let columns = [
            makeColumn(id: "col-1", name: "Ideas"),
            makeColumn(id: "col-2", name: "Building")
        ]
        let requests = [
            makeItem(id: "req-1", columnId: "col-1"),
            makeItem(id: "req-2", columnId: nil),
            makeItem(id: "req-3", columnId: "col-hidden"),
            makeItem(id: "req-4", columnId: "col-2"),
            makeItem(id: "req-5", columnId: "col-1"),
            makeItem(id: "req-6", columnId: nil),
            makeItem(id: "req-7", columnId: "col-archived")
        ]

        let groups = makeGroups(columns: columns, requests: requests)

        #expect(groups.count == 3)
        #expect(groups[0].requests == [requests[0], requests[4]])
        #expect(groups[1].requests == [requests[3]])
        #expect(groups[2].column == nil)
        #expect(groups[2].requests == [requests[1], requests[2], requests[5], requests[6]])

        let totalGroupedRequests = groups.reduce(0) { $0 + $1.requests.count }
        #expect(totalGroupedRequests == requests.count)
    }

    @Test func emptyColumnsWithNonEmptyRequestsGroupsAllUnderOtherGroup() {
        let requests = [
            makeItem(id: "req-1", columnId: "col-any"),
            makeItem(id: "req-2", columnId: nil)
        ]

        let groups = makeGroups(columns: [], requests: requests)

        #expect(groups.count == 1)
        #expect(groups[0].column == nil)
        #expect(groups[0].id == "uncategorized")
        #expect(groups[0].requests == requests)
    }

    @Test func emptyRequestsWithNonEmptyColumnsProducesEmptyGroupsForEachColumn() {
        let columns = [
            makeColumn(id: "col-1", name: "Todo"),
            makeColumn(id: "col-2", name: "Done")
        ]

        let groups = makeGroups(columns: columns, requests: [])

        #expect(groups.count == 2)
        #expect(groups[0].column?.id == "col-1")
        #expect(groups[0].requests.isEmpty)
        #expect(groups[1].column?.id == "col-2")
        #expect(groups[1].requests.isEmpty)
    }

    @Test func emptyColumnsAndRequestsProducesEmptyGroups() {
        let groups = makeGroups(columns: [], requests: [])
        #expect(groups.isEmpty)
    }
}
