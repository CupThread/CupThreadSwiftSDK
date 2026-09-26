import Foundation
import SwiftUI
import Testing
@testable import CupThreadFeedback

@Suite("RoadmapBoardView and Support Views")
struct RoadmapBoardViewTests {
    private func makeTestClient() -> FeedbackClient {
        makeClient(appKey: "app_test_dummy_key_123456")
    }

    private func makeColumn(id: String, name: String, slug: String = "planned") -> BoardColumn {
        BoardColumn(
            id: id,
            appId: "app-1",
            name: name,
            slug: slug,
            position: 0,
            isVisible: true,
            isSystem: false,
            kind: .normal,
            createdAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-01-01T00:00:00.000Z"
        )
    }

    private func makeItem(
        id: String,
        title: String = "Test Feature",
        description: String = "Feature description",
        columnId: String? = "col-1",
        voteCount: Int = 5,
        hasVoted: Bool = false,
        versionLabel: String? = nil,
        recentCommenters: [RecentCommenter] = [],
        hasMoreCommenters: Bool = false
    ) -> FeatureRequestItem {
        FeatureRequestItem(
            id: id,
            appId: "app-1",
            title: title,
            description: description,
            status: columnId ?? "planned",
            columnId: columnId,
            columnSlug: columnId.map { "slug-\($0)" },
            columnName: columnId.map { "Name-\($0)" },
            versionId: nil,
            versionLabel: versionLabel,
            releasedVersion: nil,
            requesterName: "Requester",
            requesterAvatarUrl: nil,
            requesterClerkId: nil,
            recentCommenters: recentCommenters,
            hasMoreCommenters: hasMoreCommenters,
            approved: true,
            voteCount: voteCount,
            hasVoted: hasVoted,
            isOwnRequest: false,
            createdAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-01-01T00:00:00.000Z"
        )
    }

    private func makeRecentCommenter(id: String, name: String) -> RecentCommenter {
        RecentCommenter(
            authorName: name,
            clerkUserId: id,
            avatarUrl: "https://example.com/avatar/\(id).png"
        )
    }

    // MARK: - ColumnCard Tests

    @Test @MainActor func columnCardRendersEmptyGroupWithPlaceholder() {
        let column = makeColumn(id: "col-1", name: "In Review")
        let group = RoadmapGroup(column: column, requests: [])
        let card = ColumnCard(group: group)

        _ = card.body
        #expect(card.group.requests.isEmpty)
        #expect(card.group.name == "In Review")
    }

    @Test @MainActor func columnCardRendersWithMultipleRequestsInLazyScroll() {
        let column = makeColumn(id: "col-1", name: "Planned")
        let items = (1...25).map { index in
            makeItem(id: "item-\(index)", title: "Feature Request #\(index)")
        }
        let group = RoadmapGroup(column: column, requests: items)
        let card = ColumnCard(group: group, highlightQuery: "Feature")

        _ = card.body
        #expect(card.group.requests.count == 25)
        #expect(card.highlightQuery == "Feature")
    }

    // MARK: - RoadmapCard Tests

    @Test @MainActor func roadmapCardRendersWithCommentersAndBadges() {
        let commenters = [
            makeRecentCommenter(id: "c-1", name: "Alice"),
            makeRecentCommenter(id: "c-2", name: "Bob"),
            makeRecentCommenter(id: "c-3", name: "Charlie")
        ]
        let item = makeItem(
            id: "feat-1",
            title: "Support Dark Mode",
            description: "Provide automatic system dark mode support",
            voteCount: 42,
            hasVoted: true,
            versionLabel: "v2.0",
            recentCommenters: commenters,
            hasMoreCommenters: true
        )
        let card = RoadmapCard(item: item, highlightQuery: "Dark")

        _ = card.body
        #expect(card.item.id == "feat-1")
        #expect(card.item.voteCount == 42)
        #expect(card.item.hasVoted)
        #expect(card.item.recentCommenters.count == 3)
        #expect(card.item.hasMoreCommenters)
    }

    @Test @MainActor func roadmapCardRendersMinimalItemWithoutExtras() {
        let item = makeItem(
            id: "feat-2",
            title: "Minimal Title",
            description: "",
            voteCount: 0,
            hasVoted: false,
            versionLabel: nil,
            recentCommenters: [],
            hasMoreCommenters: false
        )
        let card = RoadmapCard(item: item)

        _ = card.body
        #expect(card.item.description.isEmpty)
        #expect(card.item.recentCommenters.isEmpty)
        #expect(card.item.versionLabel == nil)
    }

    // MARK: - ColumnChip Tests

    @Test @MainActor func columnChipEvaluatesAndTriggersAction() {
        var didTap = false
        let chip = ColumnChip(
            name: "Completed",
            count: 12,
            isSelected: true
        ) {
            didTap = true
        }

        _ = chip.body
        #expect(chip.name == "Completed")
        #expect(chip.count == 12)
        #expect(chip.isSelected)

        chip.action()
        #expect(didTap)
    }

    @Test @MainActor func columnChipUnselectedRendersCorrectly() {
        let chip = ColumnChip(
            name: "Under Consideration",
            count: 3,
            isSelected: false
        ) {}

        _ = chip.body
        #expect(!chip.isSelected)
    }

    // MARK: - EmptyColumnView Tests

    @Test @MainActor func emptyColumnViewRendersBody() {
        let emptyView = EmptyColumnView()
        _ = emptyView.body
    }

    // MARK: - RoadmapBoardView Integration Tests

    @Test @MainActor func roadmapBoardViewRendersWithPreloadedGroups() {
        let client = makeTestClient()
        let col1 = makeColumn(id: "col-1", name: "Planned")
        let col2 = makeColumn(id: "col-2", name: "In Progress")
        let col3 = makeColumn(id: "col-3", name: "Done")

        let items1 = (1...10).map { makeItem(id: "col1-item-\($0)", columnId: "col-1") }
        let items2 = (1...20).map { makeItem(id: "col2-item-\($0)", columnId: "col-2") }
        let groups = [
            RoadmapGroup(column: col1, requests: items1),
            RoadmapGroup(column: col2, requests: items2),
            RoadmapGroup(column: col3, requests: [])
        ]

        let board = RoadmapBoardView(
            client: client,
            userToken: "user_test_token_123",
            initialSearchText: "",
            initialGroups: groups
        )

        _ = board.body
    }
}
