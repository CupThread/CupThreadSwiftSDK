import Foundation
import Testing
@testable import CupThreadFeedback

@Suite("FeatureRequestVoteBounds")
struct FeatureRequestVoteBoundsTests {
    private func makeItem(
        id: String = "fr-bounds-1",
        voteCount: Int = 0,
        hasVoted: Bool = true
    ) -> FeatureRequestItem {
        FeatureRequestItem(
            id: id,
            appId: "app-test-bounds",
            title: "Test Bounds Item",
            description: "Testing non-negative vote count invariant",
            status: "planned",
            approved: true,
            voteCount: voteCount,
            hasVoted: hasVoted,
            isOwnRequest: false,
            createdAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-01-01T00:00:00.000Z"
        )
    }

    @Test func withVoteStateClampsNegativeCountToZero() {
        let item = makeItem(voteCount: 0, hasVoted: true)
        let updated = item.withVoteState(voted: false, count: -1)
        #expect(updated.voteCount == 0)
        #expect(updated.hasVoted == false)

        let severelyNegative = item.withVoteState(voted: false, count: -100)
        #expect(severelyNegative.voteCount == 0)
    }

    @Test func initializerClampsNegativeVoteCountToZero() {
        let item = FeatureRequestItem(
            id: "fr-neg-init",
            appId: "app-1",
            title: "Negative Init",
            description: "Desc",
            status: "planned",
            approved: true,
            voteCount: -10,
            hasVoted: false,
            isOwnRequest: false,
            createdAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-01-01T00:00:00.000Z"
        )
        #expect(item.voteCount == 0)
    }

    @Test func decoderClampsNegativeVoteCountToZero() throws {
        let json = Data("""
        {
            "id": "fr-neg-json",
            "appId": "app-1",
            "title": "Negative JSON",
            "description": "Desc",
            "status": "planned",
            "approved": true,
            "voteCount": -42,
            "hasVoted": true,
            "isOwnRequest": false,
            "createdAt": "2026-01-01T00:00:00.000Z"
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(FeatureRequestItem.self, from: json)
        #expect(decoded.voteCount == 0)
    }

    @Test func optimisticVoteClampsVoteCountToZeroWhenUnvotingZeroCountItem() {
        let initial = makeItem(voteCount: 0, hasVoted: true)
        var state = FeatureRequestsListState(items: [initial])

        let result = state.applyOptimisticVote(for: initial.id)
        #expect(result?.originalVoted == true)
        #expect(result?.originalCount == 0)

        #expect(state.items[0].hasVoted == false)
        #expect(state.items[0].voteCount == 0)
    }

    @Test func reconcileVoteSuccessSanitizesNegativeCounts() {
        let initial = makeItem(voteCount: 5, hasVoted: false)
        var state = FeatureRequestsListState(items: [initial])

        _ = state.applyOptimisticVote(for: initial.id)
        state.reconcileVoteSuccess(itemId: initial.id, voted: false, voteCount: -3)

        #expect(state.items[0].voteCount == 0)
    }

    @Test func reconcileVoteFailureSanitizesNegativeCounts() {
        let initial = makeItem(voteCount: 5, hasVoted: false)
        var state = FeatureRequestsListState(items: [initial])

        _ = state.applyOptimisticVote(for: initial.id)
        state.reconcileVoteFailure(itemId: initial.id, originalVoted: false, originalCount: -2)

        #expect(state.items[0].voteCount == 0)
    }
}
