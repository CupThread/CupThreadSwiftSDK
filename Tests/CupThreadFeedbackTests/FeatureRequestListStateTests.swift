import Foundation
import Testing
@testable import CupThreadFeedback

@Suite("FeatureRequestListState")
struct FeatureRequestListStateTests {

    private func makeItem(
        id: String = "fr-1",
        title: String = "Initial Title",
        description: String = "Initial Description",
        status: String = "backlog",
        columnName: String? = "Backlog",
        voteCount: Int = 5,
        hasVoted: Bool = false,
        recentCommenters: [RecentCommenter] = [],
        hasMoreCommenters: Bool = false
    ) -> FeatureRequestItem {
        FeatureRequestItem(
            id: id,
            appId: "app-1",
            title: title,
            description: description,
            status: status,
            columnId: "col-1",
            columnSlug: "backlog",
            columnName: columnName,
            versionId: nil,
            versionLabel: nil,
            releasedVersion: nil,
            requesterName: "User",
            requesterAvatarUrl: nil,
            requesterClerkId: "user-1",
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

    // MARK: - Initial state

    @Test func initialStateIsEmpty() {
        let state = FeatureRequestsListState()
        #expect(state.items.isEmpty)
        #expect(state.votingIds.isEmpty)
        #expect(!state.isVoting(for: "fr-1"))
    }

    // MARK: - Optimistic voting transitions

    @Test func startVoteAppliesOptimisticIncrement() {
        let item = makeItem(voteCount: 5, hasVoted: false)
        var state = FeatureRequestsListState(items: [item])

        let inFlight = state.startVote(for: item)
        #expect(inFlight != nil)
        #expect(inFlight?.originalVoted == false)
        #expect(inFlight?.originalVoteCount == 5)
        #expect(inFlight?.optimisticVoted == true)
        #expect(inFlight?.optimisticVoteCount == 6)

        #expect(state.items.count == 1)
        #expect(state.items[0].hasVoted == true)
        #expect(state.items[0].voteCount == 6)
        #expect(state.isVoting(for: "fr-1"))
    }

    @Test func startVoteAppliesOptimisticDecrement() {
        let item = makeItem(voteCount: 5, hasVoted: true)
        var state = FeatureRequestsListState(items: [item])

        let inFlight = state.startVote(for: item)
        #expect(inFlight != nil)
        #expect(inFlight?.originalVoted == true)
        #expect(inFlight?.originalVoteCount == 5)
        #expect(inFlight?.optimisticVoted == false)
        #expect(inFlight?.optimisticVoteCount == 4)

        #expect(state.items[0].hasVoted == false)
        #expect(state.items[0].voteCount == 4)
    }

    @Test func startVoteClampsAtZeroWhenUnvotingWithZeroCount() {
        let item = makeItem(voteCount: 0, hasVoted: true)
        var state = FeatureRequestsListState(items: [item])

        _ = state.startVote(for: item)
        #expect(state.items[0].hasVoted == false)
        #expect(state.items[0].voteCount == 0)
    }

    @Test func doubleTapGuardPreventsDuplicateInFlightVote() {
        let item = makeItem(voteCount: 5, hasVoted: false)
        var state = FeatureRequestsListState(items: [item])

        let first = state.startVote(for: item)
        #expect(first != nil)

        // Second tap while in-flight must be rejected
        let second = state.startVote(for: item)
        #expect(second == nil)
        #expect(state.items[0].voteCount == 6)
        #expect(state.items[0].hasVoted == true)
    }

    @Test func startVoteOnMissingItemReturnsNil() {
        let item = makeItem(id: "missing")
        var state = FeatureRequestsListState(items: [])

        #expect(state.startVote(for: item) == nil)
        #expect(state.votingIds.isEmpty)
    }

    // MARK: - Vote reconcile: Success

    @Test func voteSucceededAppliesAuthoritativeCounts() {
        let item = makeItem(voteCount: 5, hasVoted: false)
        var state = FeatureRequestsListState(items: [item])

        state.startVote(for: item)
        let updated = state.voteSucceeded(itemId: "fr-1", voted: true, voteCount: 10)

        #expect(updated == true)
        #expect(state.items[0].hasVoted == true)
        #expect(state.items[0].voteCount == 10)
        #expect(!state.isVoting(for: "fr-1"))
        #expect(state.inFlightVote(for: "fr-1") == nil)
    }

    // MARK: - Vote reconcile: Failure without reload

    @Test func voteFailedRevertsOptimisticUpdateWithoutReload() {
        let item = makeItem(voteCount: 5, hasVoted: false)
        var state = FeatureRequestsListState(items: [item])

        state.startVote(for: item)
        #expect(state.items[0].hasVoted == true)
        #expect(state.items[0].voteCount == 6)

        let reverted = state.voteFailed(itemId: "fr-1")
        #expect(reverted == true)
        #expect(state.items[0].hasVoted == false)
        #expect(state.items[0].voteCount == 5)
        #expect(!state.isVoting(for: "fr-1"))
        #expect(state.inFlightVote(for: "fr-1") == nil)
    }

    // MARK: - Concurrency: Concurrent reload during in-flight vote (Issue #64)

    @Test func voteFailedPreservesFreshServerDataWhenReloadOccursMidFlight() {
        let initialItem = makeItem(
            id: "fr-1",
            title: "Old Stale Title",
            description: "Old Stale Description",
            columnName: "Backlog",
            voteCount: 5,
            hasVoted: false,
            recentCommenters: []
        )
        var state = FeatureRequestsListState(items: [initialItem])

        // 1. User starts an optimistic vote.
        _ = state.startVote(for: initialItem)
        #expect(state.items[0].hasVoted == true)
        #expect(state.items[0].voteCount == 6)

        // 2. A concurrent list reload completes while the vote is in-flight.
        let commenter = RecentCommenter(authorName: "Alice", clerkUserId: "clerk_alice", avatarUrl: nil)
        let freshServerItem = makeItem(
            id: "fr-1",
            title: "Fresh Authoritative Title",
            description: "Fresh Authoritative Description",
            columnName: "In Progress",
            voteCount: 5,
            hasVoted: false,
            recentCommenters: [commenter],
            hasMoreCommenters: true
        )
        state.reloadItems([freshServerItem])

        // The in-flight optimistic vote state is preserved over the fresh metadata.
        #expect(state.items[0].title == "Fresh Authoritative Title")
        #expect(state.items[0].description == "Fresh Authoritative Description")
        #expect(state.items[0].columnName == "In Progress")
        #expect(state.items[0].recentCommenters.count == 1)
        #expect(state.items[0].hasMoreCommenters == true)
        #expect(state.items[0].hasVoted == true)
        #expect(state.items[0].voteCount == 6)

        // 3. The vote fails (e.g. network failure, 429 rate limit, 500 error).
        let reverted = state.voteFailed(itemId: "fr-1")
        #expect(reverted == true)

        // CRITICAL ASSERTION: The fresh server metadata must survive and NOT roll back
        // to the pre-reload snapshot ("Old Stale Title"). Only vote fields revert.
        #expect(state.items[0].title == "Fresh Authoritative Title")
        #expect(state.items[0].description == "Fresh Authoritative Description")
        #expect(state.items[0].columnName == "In Progress")
        #expect(state.items[0].recentCommenters.count == 1)
        #expect(state.items[0].hasMoreCommenters == true)
        #expect(state.items[0].hasVoted == false)
        #expect(state.items[0].voteCount == 5)
        #expect(!state.isVoting(for: "fr-1"))
    }

    @Test func voteSucceededPreservesFreshServerDataWhenReloadOccursMidFlight() {
        let initialItem = makeItem(
            id: "fr-1",
            title: "Initial Title",
            voteCount: 5,
            hasVoted: false
        )
        var state = FeatureRequestsListState(items: [initialItem])

        _ = state.startVote(for: initialItem)

        let freshServerItem = makeItem(
            id: "fr-1",
            title: "Updated Title from Server",
            voteCount: 5,
            hasVoted: false
        )
        state.reloadItems([freshServerItem])

        _ = state.voteSucceeded(itemId: "fr-1", voted: true, voteCount: 6)

        #expect(state.items[0].title == "Updated Title from Server")
        #expect(state.items[0].hasVoted == true)
        #expect(state.items[0].voteCount == 6)
        #expect(!state.isVoting(for: "fr-1"))
    }

    @Test func rowShiftDuringInFlightVoteReconcilesCorrectRow() {
        let itemA = makeItem(id: "fr-a", title: "Item A", voteCount: 1, hasVoted: false)
        let itemB = makeItem(id: "fr-b", title: "Item B", voteCount: 10, hasVoted: false)
        var state = FeatureRequestsListState(items: [itemA, itemB])

        // Vote on Item B (index 1)
        _ = state.startVote(for: itemB)
        #expect(state.items[1].hasVoted == true)
        #expect(state.items[1].voteCount == 11)

        // Reload arrives with rows reordered (Item B now at index 0, Item A at index 1)
        let reloadedB = makeItem(id: "fr-b", title: "Item B Fresh", voteCount: 10, hasVoted: false)
        let reloadedA = makeItem(id: "fr-a", title: "Item A Fresh", voteCount: 1, hasVoted: false)
        state.reloadItems([reloadedB, reloadedA])

        #expect(state.items[0].id == "fr-b")
        #expect(state.items[0].title == "Item B Fresh")
        #expect(state.items[0].hasVoted == true)
        #expect(state.items[0].voteCount == 11)

        #expect(state.items[1].id == "fr-a")
        #expect(state.items[1].title == "Item A Fresh")
        #expect(state.items[1].hasVoted == false)
        #expect(state.items[1].voteCount == 1)

        // Vote fails on Item B
        state.voteFailed(itemId: "fr-b")

        // Item B at index 0 reverted vote fields, while Item A at index 1 remains untouched
        #expect(state.items[0].id == "fr-b")
        #expect(state.items[0].title == "Item B Fresh")
        #expect(state.items[0].hasVoted == false)
        #expect(state.items[0].voteCount == 10)

        #expect(state.items[1].id == "fr-a")
        #expect(state.items[1].title == "Item A Fresh")
        #expect(state.items[1].hasVoted == false)
        #expect(state.items[1].voteCount == 1)
    }

    @Test func deletedItemDuringInFlightVoteDoesNotResurrect() {
        let itemA = makeItem(id: "fr-a", title: "Item A")
        var state = FeatureRequestsListState(items: [itemA])

        _ = state.startVote(for: itemA)

        // Reload returns an empty list (Item A was deleted on server)
        state.reloadItems([])
        #expect(state.items.isEmpty)

        // Vote failure for the deleted item
        let result = state.voteFailed(itemId: "fr-a")
        #expect(result == false)
        #expect(state.items.isEmpty)
        #expect(!state.isVoting(for: "fr-a"))
    }

    @Test func concurrentVotesOnMultipleItemsAreIndependent() {
        let itemA = makeItem(id: "fr-a", voteCount: 2, hasVoted: false)
        let itemB = makeItem(id: "fr-b", voteCount: 4, hasVoted: false)
        var state = FeatureRequestsListState(items: [itemA, itemB])

        _ = state.startVote(for: itemA)
        _ = state.startVote(for: itemB)

        #expect(state.isVoting(for: "fr-a"))
        #expect(state.isVoting(for: "fr-b"))
        #expect(state.items[0].voteCount == 3)
        #expect(state.items[1].voteCount == 5)

        // A fails, B succeeds
        state.voteFailed(itemId: "fr-a")
        state.voteSucceeded(itemId: "fr-b", voted: true, voteCount: 5)

        #expect(!state.isVoting(for: "fr-a"))
        #expect(!state.isVoting(for: "fr-b"))
        #expect(state.items[0].hasVoted == false)
        #expect(state.items[0].voteCount == 2)
        #expect(state.items[1].hasVoted == true)
        #expect(state.items[1].voteCount == 5)
    }
}
