import SwiftUI
import Testing
@testable import CupThreadFeedback

@Suite("FeatureRequestsLoadState Tests")
struct FeatureRequestsLoadStateTests {
    // MARK: - Lifecycle Invariant (Issue #286)

    @Test func cancelledLoadDoesNotResolveLifecycle() {
        var state = FeatureRequestsLoadState()
        let generation = state.startLoading()

        #expect(state.isLoading)
        #expect(!state.hasLoadedOnce)

        // The load was cancelled before its fetch reached a verdict —
        // finishing it must leave both flags untouched so the skeleton keeps
        // rendering instead of a fabricated empty state.
        state.finishLoading(generation: generation, wasCancelled: true)

        #expect(state.isLoading)
        #expect(!state.hasLoadedOnce)

        // The next load (not cancelled) resolves the lifecycle normally.
        let nextGeneration = state.startLoading()
        state.finishLoading(generation: nextGeneration, wasCancelled: false)

        #expect(!state.isLoading)
        #expect(state.hasLoadedOnce)
    }

    @Test func supersededLoadDoesNotResolveLifecycle() {
        var state = FeatureRequestsLoadState()

        // Load A starts, then load B restarts over it (search keystroke,
        // version filter, pull-to-refresh).
        let generationA = state.startLoading()
        let generationB = state.startLoading()
        #expect(generationB == generationA + 1)

        // A finishes after B: it never reached a verdict for the current
        // generation, so it must not clear the loading indicator B owns.
        state.finishLoading(generation: generationA, wasCancelled: false)

        #expect(state.isLoading)
        #expect(!state.hasLoadedOnce)

        // B's completion resolves the lifecycle.
        state.finishLoading(generation: generationB, wasCancelled: false)

        #expect(!state.isLoading)
        #expect(state.hasLoadedOnce)
    }

    @Test func staleCancelledLoadWritesNothing() {
        var state = FeatureRequestsLoadState()
        let generationA = state.startLoading()
        _ = state.startLoading()

        // A load that is both stale and cancelled — the common restarted
        // search path — writes nothing at all.
        state.finishLoading(generation: generationA, wasCancelled: true)

        #expect(state.isLoading)
        #expect(!state.hasLoadedOnce)
    }

    @Test func completedLoadResolvesLifecycle() {
        var state = FeatureRequestsLoadState()
        let generation = state.startLoading()

        state.finishLoading(generation: generation, wasCancelled: false)

        #expect(!state.isLoading)
        #expect(state.hasLoadedOnce)
    }

    @Test func restartAfterCancelledFirstLoadKeepsSkeletonCondition() {
        var state = FeatureRequestsLoadState()

        // First load cancelled by the replacement load's restart.
        let firstGeneration = state.startLoading()
        state.finishLoading(generation: firstGeneration, wasCancelled: true)

        // The replacement load starts; the skeleton branch
        // (`isLoading && !hasLoadedOnce`) must still hold — not the empty state.
        _ = state.startLoading()

        #expect(state.isLoading)
        #expect(!state.hasLoadedOnce)
    }

    @Test func startLoadingIncrementsGenerationMonotonically() {
        var state = FeatureRequestsLoadState()
        #expect(state.loadGeneration == 0)

        #expect(state.startLoading() == 1)
        #expect(state.startLoading() == 2)
        #expect(state.startLoading() == 3)
        #expect(state.loadGeneration == 3)
    }

    // MARK: - View Presentation

    @Test @MainActor func featureRequestsViewFirstRenderKeepsSkeletonCondition() {
        let view = FeatureRequestsView(
            client: makeClient(appKey: "app_test_dummy_key_123456"),
            userToken: "test_token"
        )

        _ = view.body
        // First presentation: the skeleton branch (`isLoading && !hasLoadedOnce`)
        // holds with no items, so the false "no requests" empty state is
        // unreachable before a verdict exists.
        #expect(view.isLoading)
        #expect(!view.hasLoadedOnce)
        #expect(view.items.isEmpty)
    }

    @Test @MainActor func featureRequestsViewResolvedEmptyStateRendersAfterVerdictOnly() {
        let view = FeatureRequestsView(
            client: makeClient(appKey: "app_test_dummy_key_123456"),
            userToken: "test_token",
            listState: FeatureRequestsListState(),
            loadState: {
                var state = FeatureRequestsLoadState()
                let generation = state.startLoading()
                state.finishLoading(generation: generation, wasCancelled: false)
                return state
            }()
        )

        _ = view.body
        // A completed verdict (no results) is the only path to the empty state.
        #expect(!view.isLoading)
        #expect(view.hasLoadedOnce)
        #expect(view.items.isEmpty)
    }

    @Test @MainActor func featureRequestsViewRendersLoadedContent() {
        let item = makeFeatureRequestItem(id: "req-1")
        let view = FeatureRequestsView(
            client: makeClient(appKey: "app_test_dummy_key_123456"),
            userToken: "test_token",
            listState: FeatureRequestsListState(items: [item]),
            loadState: {
                var state = FeatureRequestsLoadState()
                let generation = state.startLoading()
                state.finishLoading(generation: generation, wasCancelled: false)
                return state
            }()
        )

        _ = view.body
        #expect(!view.isLoading)
        #expect(view.hasLoadedOnce)
        #expect(view.items.count == 1)
    }

    private func makeFeatureRequestItem(id: String) -> FeatureRequestItem {
        FeatureRequestItem(
            id: id,
            appId: "app-1",
            title: "Dark mode",
            description: "Ship a dark theme.",
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
            voteCount: 3,
            hasVoted: false,
            isOwnRequest: false,
            createdAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-01-01T00:00:00.000Z"
        )
    }
}
