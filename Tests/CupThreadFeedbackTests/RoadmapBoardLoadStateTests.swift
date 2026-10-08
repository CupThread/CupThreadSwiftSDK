import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Load task key (issue #274)

@Suite("RoadmapBoardLoadTaskKey")
struct RoadmapBoardLoadTaskKeyTests {
    @Test func permissionFlipChangesTheKeyWithStableSearchText() {
        // The denied→permitted config transition from #274: the task must
        // restart even though the query is unchanged. Keyed on the search
        // text alone (the main behavior), the id never changed here.
        #expect(
            makeRoadmapLoadTaskKey(isRoadmapPermitted: false, trimmedSearchText: "dark mode")
                != makeRoadmapLoadTaskKey(isRoadmapPermitted: true, trimmedSearchText: "dark mode")
        )
    }

    @Test func keystrokeChangesTheKeyWithStableVerdict() {
        // The pre-existing debounce behavior: every query change restarts the
        // task while the verdict stays permitted.
        #expect(
            makeRoadmapLoadTaskKey(isRoadmapPermitted: true, trimmedSearchText: "dark")
                != makeRoadmapLoadTaskKey(isRoadmapPermitted: true, trimmedSearchText: "dark mode")
        )
    }

    @Test func unchangedVerdictAndQueryProduceTheSameKey() {
        // A verdict-stable config refresh must not restart the in-flight load.
        #expect(
            makeRoadmapLoadTaskKey(isRoadmapPermitted: true, trimmedSearchText: "")
                == makeRoadmapLoadTaskKey(isRoadmapPermitted: true, trimmedSearchText: "")
        )
        #expect(
            makeRoadmapLoadTaskKey(isRoadmapPermitted: false, trimmedSearchText: "")
                == makeRoadmapLoadTaskKey(isRoadmapPermitted: false, trimmedSearchText: "")
        )
    }
}

// MARK: - Load lifecycle (issue #274)

@Suite("RoadmapBoardLoadState")
struct RoadmapBoardLoadStateTests {
    @Test func initialStateIsFirstLoading() {
        let state = RoadmapBoardLoadState()
        #expect(state.isLoading)
        #expect(!state.hasLoadedOnce)
        #expect(state.loadError == nil)
        #expect(state.loadGeneration == 0)
    }

    @Test func startLoadingBumpsGenerationAndClearsPreviousError() {
        var state = RoadmapBoardLoadState()
        state.loadError = "Network unreachable"

        let generation = state.startLoading()

        #expect(generation == 1)
        #expect(state.isLoading)
        #expect(state.loadError == nil)

        #expect(state.startLoading() == 2)
        #expect(state.loadGeneration == 2)
    }

    @Test func finishLoadingSettlesTheFirstLoad() {
        var state = RoadmapBoardLoadState()
        let generation = state.startLoading()

        state.finishLoading(generation: generation)

        #expect(!state.isLoading)
        #expect(state.hasLoadedOnce)
    }

    @Test func supersededFinishLoadingLeavesTheFlagsToTheNewerLoad() {
        var state = RoadmapBoardLoadState()
        let first = state.startLoading()
        let second = state.startLoading()

        state.finishLoading(generation: first)
        #expect(state.isLoading, "The newer load is still in flight")
        #expect(!state.hasLoadedOnce)

        state.finishLoading(generation: second)
        #expect(!state.isLoading)
        #expect(state.hasLoadedOnce)
    }

    @Test func settledPermissionDeniedEndsTheFirstLoadAndLeavesNoLoadingState() {
        // Acceptance criterion 1 (state level): after the denied task run
        // settles the lifecycle, the board must not report the first-load
        // skeleton anymore — the permanent-.loading strand from #274.
        var state = RoadmapBoardLoadState()
        state.settlePermissionDenied()

        #expect(!state.isLoading)
        #expect(state.hasLoadedOnce)
        #expect(state.loadError == nil)

        let displayState = makeBoardDisplayState(
            isLoading: state.isLoading,
            hasLoadedOnce: state.hasLoadedOnce,
            loadError: state.loadError,
            searchText: "",
            groups: []
        )
        #expect(displayState == .emptyBoard)
    }

    @Test func settledPermissionDeniedInvalidatesAnInFlightPermittedLoad() {
        // Acceptance criterion 2: a permitted load still in flight when the
        // verdict flips to denied must not write its results or errors behind
        // the placeholder — including the unstructured refreshable path that
        // SwiftUI's task cancellation does not reach.
        var state = RoadmapBoardLoadState()
        let inFlight = state.startLoading()

        state.settlePermissionDenied()

        #expect(!state.isCurrent(generation: inFlight))
        state.finishLoading(generation: inFlight)
        #expect(!state.isLoading && state.hasLoadedOnce, "The denial settle's flags stand; the stale finish is a no-op")
        #expect(state.loadGeneration == 2)

        state.handleFailure(message: "stale failure", generation: inFlight)
        #expect(state.loadError == nil)
    }

    @Test func deniedSettleAfterContentLoadedKeepsGroupsAndClearsTransientState() {
        // permitted with content → denied: the placeholder takes over and any
        // pending notice is dropped; the loaded groups stay so a permitted
        // flip can show content while its reload runs instead of flashing.
        var state = RoadmapBoardLoadState()
        state.settlePermissionDenied()
        let generation = state.startLoading()
        state.finishLoading(generation: generation)
        state.loadError = "expired error"

        state.settlePermissionDenied()

        #expect(state.loadError == nil)
        #expect(!state.isLoading)
        #expect(state.hasLoadedOnce)
    }

    @Test func handleFailureAppliesOnlyToTheCurrentGeneration() {
        var state = RoadmapBoardLoadState()
        let first = state.startLoading()
        let second = state.startLoading()

        state.handleFailure(message: "stale", generation: first)
        #expect(state.loadError == nil)

        state.handleFailure(message: "current", generation: second)
        #expect(state.loadError == "current")
    }

    @Test func deniedThenPermittedRestartLoadsTheBoardAgain() {
        // The #274 sequence end to end at the state level: denied settle,
        // then a permitted flip restarts a load whose success leaves the
        // board renderable — never stuck in `.loading`.
        var state = RoadmapBoardLoadState()
        state.settlePermissionDenied()

        let generation = state.startLoading()
        #expect(state.isCurrent(generation: generation))

        state.finishLoading(generation: generation)
        let displayState = makeBoardDisplayState(
            isLoading: state.isLoading,
            hasLoadedOnce: state.hasLoadedOnce,
            loadError: state.loadError,
            searchText: "",
            groups: []
        )
        #expect(displayState == .emptyBoard)
        #expect(displayState != .loading)
    }

    // MARK: - Cancellation & Concurrency Invariants (Issue #187 / CONC-5)

    @Test func cancelledLoadDoesNotResolveLifecycle() {
        var state = RoadmapBoardLoadState()
        let generation = state.startLoading()

        #expect(state.isLoading)
        #expect(!state.hasLoadedOnce)

        // The load was cancelled before reaching a completed verdict —
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

    @Test func staleCancelledLoadWritesNothing() {
        var state = RoadmapBoardLoadState()
        let generationA = state.startLoading()
        _ = state.startLoading()

        // A load that is both stale and cancelled — the common restarted
        // search path — writes nothing at all.
        state.finishLoading(generation: generationA, wasCancelled: true)

        #expect(state.isLoading)
        #expect(!state.hasLoadedOnce)
    }

    @Test func restartAfterCancelledFirstLoadKeepsSkeletonCondition() {
        var state = RoadmapBoardLoadState()

        // First load cancelled by the replacement load's restart.
        let firstGeneration = state.startLoading()
        state.finishLoading(generation: firstGeneration, wasCancelled: true)

        // The replacement load starts; the skeleton branch
        // (`isLoading && !hasLoadedOnce`) must still hold — not the empty state.
        _ = state.startLoading()

        #expect(state.isLoading)
        #expect(!state.hasLoadedOnce)
    }

    private func makeTestGroup(columnId: String, requestId: String, title: String) -> [RoadmapGroup] {
        let col = BoardColumn(
            id: columnId,
            appId: "app-1",
            name: "Planned",
            slug: "planned",
            position: 0,
            isVisible: true,
            isSystem: false,
            kind: .normal,
            createdAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-01-01T00:00:00.000Z"
        )
        return [
            RoadmapGroup(
                column: col,
                requests: [
                    FeatureRequestItem(
                        id: requestId,
                        appId: "app-1",
                        title: title,
                        description: "Description",
                        status: columnId,
                        columnId: columnId,
                        columnSlug: "planned",
                        columnName: "Planned",
                        versionId: nil,
                        versionLabel: nil,
                        releasedVersion: nil,
                        requesterName: "User",
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
                ]
            )
        ]
    }

    @Test func overlappingLoadsDiscardStaleResultsAndPreserveAuthoritativeContent() {
        // CONC-5 (Issue #187): simulate two overlapping loads:
        // Load 1: slower, multi-page / delayed query ("sync")
        // Load 2: faster query ("")
        var loadState = RoadmapBoardLoadState()
        var groups: [RoadmapGroup] = []
        var lastExecutedQuery = ""

        let load1Groups = makeTestGroup(columnId: "col-1", requestId: "req-stale", title: "Stale Sync Feature")
        let load2Groups = makeTestGroup(columnId: "col-1", requestId: "req-fresh", title: "Fresh Empty Query Feature")

        // 1. Start Load 1 ("sync")
        let gen1 = loadState.startLoading()
        let query1 = "sync"

        // 2. Start Load 2 ("")
        let gen2 = loadState.startLoading()
        let query2 = ""

        #expect(gen2 > gen1)
        #expect(loadState.isLoading)

        // 3. Allow Load 2 to complete and populate groups
        if loadState.isCurrent(generation: gen2) {
            groups = load2Groups
            lastExecutedQuery = query2
        }
        loadState.finishLoading(generation: gen2, wasCancelled: false)

        #expect(groups == load2Groups)
        #expect(lastExecutedQuery.isEmpty)
        #expect(!loadState.isLoading)
        #expect(loadState.hasLoadedOnce)

        // 4. Allow Load 1 to complete afterwards (stale generation is discarded)
        if loadState.isCurrent(generation: gen1) {
            groups = load1Groups
            lastExecutedQuery = query1
        }
        loadState.finishLoading(generation: gen1, wasCancelled: false)

        // 5. Verify that Load 1's results are discarded and groups matches Load 2's content
        #expect(groups == load2Groups)
        #expect(lastExecutedQuery.isEmpty)
        #expect(!loadState.isLoading)
        #expect(loadState.hasLoadedOnce)
    }

    @Test func overlappingFailureFromStaleLoadDoesNotOverwriteContentOrSetError() {
        var loadState = RoadmapBoardLoadState()
        let gen1 = loadState.startLoading()
        let gen2 = loadState.startLoading()

        // Load 2 completes successfully
        loadState.finishLoading(generation: gen2, wasCancelled: false)
        #expect(loadState.loadError == nil)

        // Stale Load 1 encounters error (e.g. rate limit or network drop)
        loadState.handleFailure(message: "Too Many Requests", generation: gen1)

        // Stale error is discarded; board remains healthy
        #expect(loadState.loadError == nil)
        #expect(!loadState.isLoading)
        #expect(loadState.hasLoadedOnce)
    }
}
