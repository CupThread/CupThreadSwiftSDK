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
}
