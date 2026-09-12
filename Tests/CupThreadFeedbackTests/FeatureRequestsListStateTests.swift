import Foundation
import Testing
@testable import CupThreadFeedback

@Suite("FeatureRequestsListState")
struct FeatureRequestsListStateTests {
    private func makeItem(
        id: String,
        title: String = "Test Title",
        description: String = "Test Description",
        status: String = "backlog",
        voteCount: Int = 5,
        hasVoted: Bool = false,
        recentCommenters: [RecentCommenter] = [],
        releasedVersion: String? = nil
    ) -> FeatureRequestItem {
        FeatureRequestItem(
            id: id,
            appId: "app-1",
            title: title,
            description: description,
            status: status,
            columnId: "col-1",
            columnSlug: "backlog",
            columnName: "Backlog",
            versionId: nil,
            versionLabel: nil,
            releasedVersion: releasedVersion,
            requesterName: "Requester",
            requesterAvatarUrl: nil,
            requesterClerkId: nil,
            recentCommenters: recentCommenters,
            hasMoreCommenters: false,
            approved: true,
            voteCount: voteCount,
            hasVoted: hasVoted,
            isOwnRequest: false,
            createdAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-01-01T00:00:00.000Z"
        )
    }

    @Test func optimisticVoteTogglesVoteAndGuardsDoubleTap() {
        let initialItem = makeItem(id: "fr-1", voteCount: 5, hasVoted: false)
        var state = FeatureRequestsListState(items: [initialItem])

        let preVote = state.applyOptimisticVote(for: "fr-1")
        #expect(preVote?.originalVoted == false)
        #expect(preVote?.originalCount == 5)

        // Optimistic update should toggle vote state and increment count
        #expect(state.items[0].hasVoted == true)
        #expect(state.items[0].voteCount == 6)
        #expect(state.votingIds.contains("fr-1"))

        // Second tap while vote is in flight must be rejected (double-tap guard)
        let secondTap = state.applyOptimisticVote(for: "fr-1")
        #expect(secondTap == nil)
        #expect(state.items[0].hasVoted == true)
        #expect(state.items[0].voteCount == 6)
    }

    @Test func optimisticVoteOnAlreadyVotedItemDecrementsCount() {
        let initialItem = makeItem(id: "fr-1", voteCount: 5, hasVoted: true)
        var state = FeatureRequestsListState(items: [initialItem])

        let preVote = state.applyOptimisticVote(for: "fr-1")
        #expect(preVote?.originalVoted == true)
        #expect(preVote?.originalCount == 5)

        #expect(state.items[0].hasVoted == false)
        #expect(state.items[0].voteCount == 4)
    }

    @Test func voteSuccessReconcilesServerCountsAndClearsVotingId() {
        let initialItem = makeItem(id: "fr-1", voteCount: 5, hasVoted: false)
        var state = FeatureRequestsListState(items: [initialItem])

        _ = state.applyOptimisticVote(for: "fr-1")
        #expect(state.votingIds.contains("fr-1"))

        state.reconcileVoteSuccess(itemId: "fr-1", voted: true, voteCount: 10)

        #expect(!state.votingIds.contains("fr-1"))
        #expect(state.items[0].hasVoted == true)
        #expect(state.items[0].voteCount == 10)
    }

    @Test func voteSuccessWithRowIndexShift() {
        let itemA = makeItem(id: "fr-a", title: "A", voteCount: 2)
        let itemB = makeItem(id: "fr-b", title: "B", voteCount: 5)
        var state = FeatureRequestsListState(items: [itemA, itemB])

        _ = state.applyOptimisticVote(for: "fr-b")

        // Suppose a reload inserted itemC at the beginning, shifting fr-b from index 1 to index 2
        let itemC = makeItem(id: "fr-c", title: "C", voteCount: 8)
        state.mergeReloadedItems([itemC, itemA, itemB])

        #expect(state.items.count == 3)
        #expect(state.items[2].id == "fr-b")

        state.reconcileVoteSuccess(itemId: "fr-b", voted: true, voteCount: 6)

        #expect(!state.votingIds.contains("fr-b"))
        #expect(state.items[2].id == "fr-b")
        #expect(state.items[2].hasVoted == true)
        #expect(state.items[2].voteCount == 6)
    }

    @Test func reloadDuringInFlightVotePreservesOptimisticState() {
        let item = makeItem(id: "fr-1", title: "Initial Title", voteCount: 5, hasVoted: false)
        var state = FeatureRequestsListState(items: [item])

        _ = state.applyOptimisticVote(for: "fr-1")
        #expect(state.items[0].voteCount == 6)
        #expect(state.items[0].hasVoted == true)

        // Reload arrives from server while vote is still in flight.
        // Server has updated title, new comments, but its vote count is still 5.
        let reloadedItem = makeItem(
            id: "fr-1",
            title: "Updated Title on Server",
            description: "New description",
            voteCount: 5,
            hasVoted: false,
            recentCommenters: [RecentCommenter(authorName: "Alice", clerkUserId: "u1", avatarUrl: nil)]
        )
        state.mergeReloadedItems([reloadedItem])

        // Fresh server metadata should be accepted
        #expect(state.items[0].title == "Updated Title on Server")
        #expect(state.items[0].description == "New description")
        #expect(state.items[0].recentCommenters.count == 1)

        // But in-flight optimistic vote state is preserved so the UI does not flicker
        #expect(state.items[0].hasVoted == true)
        #expect(state.items[0].voteCount == 6)
        #expect(state.votingIds.contains("fr-1"))
    }

    @Test func reloadDuringInFlightVoteFailurePreservesFreshServerFieldsAndRevertsVoteOnly() throws {
        let item = makeItem(
            id: "fr-1",
            title: "Old Title",
            description: "Old Desc",
            status: "backlog",
            voteCount: 5,
            hasVoted: false
        )
        var state = FeatureRequestsListState(items: [item])

        let applied = state.applyOptimisticVote(for: "fr-1")
        let preVote = try #require(applied)
        let originalVoted = preVote.originalVoted
        let originalCount = preVote.originalCount

        // Reload completes while vote is in flight
        let freshItem = makeItem(
            id: "fr-1",
            title: "Brand New Title",
            description: "Brand New Desc",
            status: "in_progress",
            voteCount: 5,
            hasVoted: false,
            recentCommenters: [RecentCommenter(authorName: "Bob", clerkUserId: "u2", avatarUrl: nil)],
            releasedVersion: "2.1.0"
        )
        state.mergeReloadedItems([freshItem])

        // Now the in-flight vote fails
        state.reconcileVoteFailure(
            itemId: "fr-1",
            originalVoted: originalVoted,
            originalCount: originalCount
        )

        // 1. Voting ID must be cleared
        #expect(state.votingIds.isEmpty)

        // 2. Vote state must be reverted to pre-vote values
        #expect(state.items[0].hasVoted == false)
        #expect(state.items[0].voteCount == 5)

        // 3. CRITICAL: The fresh server data must NOT have been wiped out by the failure revert!
        #expect(state.items[0].title == "Brand New Title")
        #expect(state.items[0].description == "Brand New Desc")
        #expect(state.items[0].status == "in_progress")
        #expect(state.items[0].recentCommenters.count == 1)
        #expect(state.items[0].recentCommenters.first?.authorName == "Bob")
        #expect(state.items[0].releasedVersion == "2.1.0")
    }

    @Test func reloadThatRemovesItemDuringInFlightVoteDoesNotResurrectOnFailure() throws {
        let itemA = makeItem(id: "fr-a", title: "A")
        var state = FeatureRequestsListState(items: [itemA])

        let applied = state.applyOptimisticVote(for: "fr-a")
        let preVote = try #require(applied)
        let originalVoted = preVote.originalVoted
        let originalCount = preVote.originalCount

        // Reload returns an empty list (e.g. search query excluded the item)
        state.mergeReloadedItems([])
        #expect(state.items.isEmpty)

        // Vote fails
        state.reconcileVoteFailure(
            itemId: "fr-a",
            originalVoted: originalVoted,
            originalCount: originalCount
        )

        // Item should not be resurrected into the filtered list
        #expect(state.items.isEmpty)
        #expect(state.votingIds.isEmpty)
    }

    @Test func multipleConcurrentVotesOnDifferentItems() throws {
        let itemA = makeItem(id: "fr-a", title: "A", voteCount: 2, hasVoted: false)
        let itemB = makeItem(id: "fr-b", title: "B", voteCount: 8, hasVoted: true)
        var state = FeatureRequestsListState(items: [itemA, itemB])

        _ = state.applyOptimisticVote(for: "fr-a")
        let appliedB = state.applyOptimisticVote(for: "fr-b")
        let preB = try #require(appliedB)

        #expect(state.votingIds == ["fr-a", "fr-b"])
        #expect(state.items[0].voteCount == 3)
        #expect(state.items[0].hasVoted == true)
        #expect(state.items[1].voteCount == 7)
        #expect(state.items[1].hasVoted == false)

        // Reload with updated titles
        let freshA = makeItem(id: "fr-a", title: "A-Updated", voteCount: 2, hasVoted: false)
        let freshB = makeItem(id: "fr-b", title: "B-Updated", voteCount: 8, hasVoted: true)
        state.mergeReloadedItems([freshA, freshB])

        // A succeeds with server returning count 4
        state.reconcileVoteSuccess(itemId: "fr-a", voted: true, voteCount: 4)
        #expect(state.votingIds == ["fr-b"])
        #expect(state.items[0].title == "A-Updated")
        #expect(state.items[0].hasVoted == true)
        #expect(state.items[0].voteCount == 4)

        // B fails, reverts to original
        state.reconcileVoteFailure(
            itemId: "fr-b",
            originalVoted: preB.originalVoted,
            originalCount: preB.originalCount
        )
        #expect(state.votingIds.isEmpty)
        #expect(state.items[1].title == "B-Updated")
        #expect(state.items[1].hasVoted == true)
        #expect(state.items[1].voteCount == 8)
    }
}
