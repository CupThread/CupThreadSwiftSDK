import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - SurfaceLoadState (CONC-4, issue #181)

/// Cancellation preserves the unresolved presentation; only the current,
/// completed generation may settle the surface.
@Suite("SurfaceLoadState")
struct SurfaceLoadStateTests {
    @Test func initialStateIsFirstLoading() {
        let state = SurfaceLoadState()
        #expect(state.isLoading)
        #expect(state.loadError == nil)
        #expect(state.loadGeneration == 0)
    }

    @Test func startLoadingBumpsGenerationClearsErrorAndShowsSpinner() {
        var state = SurfaceLoadState()
        state.loadError = "stale failure"
        let generation = state.startLoading()
        #expect(generation == 1)
        #expect(state.isLoading)
        #expect(state.loadError == nil)
        #expect(state.loadGeneration == 1)
    }

    @Test func finishLoadingResetsIsLoadingForCurrentGeneration() {
        var state = SurfaceLoadState()
        let generation = state.startLoading()
        state.finishLoading(generation: generation)
        #expect(!state.isLoading)
    }

    @Test func cancelledLoadPreservesSpinnerUntilReplacementSettles() {
        var state = SurfaceLoadState()
        let generation = state.startLoading()
        state.finishLoading(generation: generation, wasCancelled: true)
        #expect(state.isLoading)
        #expect(state.loadError == nil)

        let replacement = state.startLoading()
        state.finishLoading(generation: replacement)
        #expect(!state.isLoading)
        #expect(state.loadError == nil)
    }

    @Test func staleCancellationDoesNotChangeReplacementState() {
        var state = SurfaceLoadState()
        let cancelled = state.startLoading()
        let replacement = state.startLoading()
        state.finishLoading(generation: cancelled, wasCancelled: true)
        #expect(state.isLoading)
        state.loadError = "replacement failed"
        state.finishLoading(generation: replacement)
        let settled = state
        state.finishLoading(generation: cancelled, wasCancelled: true)
        #expect(state == settled)
        #expect(!state.isLoading)
    }

    @Test func cancelledRefreshWaitsForAResolvedRetry() {
        var state = SurfaceLoadState()
        let initial = state.startLoading()
        state.finishLoading(generation: initial)
        let refresh = state.startLoading()
        state.finishLoading(generation: refresh, wasCancelled: true)
        #expect(state.isLoading)
        #expect(state.loadError == nil)

        let retry = state.startLoading()
        state.loadError = "retry failed"
        state.finishLoading(generation: retry)
        #expect(!state.isLoading)
        #expect(state.loadError == "retry failed")
    }

    @Test func supersededGenerationIsNotCurrent() {
        var state = SurfaceLoadState()
        let first = state.startLoading()
        let second = state.startLoading()
        #expect(first != second)
        #expect(!state.isCurrent(generation: first))
        #expect(state.isCurrent(generation: second))
    }

    @Test func supersededFinishLoadingLeavesTheNewerRunsSpinnerAlone() {
        // Issue #181 test case 2 (out-of-order resolution): load 1 is still
        // in flight when load 2 starts and finishes first. Load 1's late
        // `defer` must not clear the spinner while load 2 is in flight.
        var state = SurfaceLoadState()
        let slowLoad = state.startLoading()
        let fastLoad = state.startLoading()
        state.finishLoading(generation: fastLoad)
        #expect(!state.isLoading)
        // The slow load lands after the fast one already owned the surface:
        #expect(!state.isCurrent(generation: slowLoad))
        state.finishLoading(generation: slowLoad)
        #expect(!state.isLoading)
    }

    @Test func supersededLoadCannotClearASettledNewerRunsState() {
        // Load 1 is superseded by load 2, which settles with an error; the
        // late load 1 defer must not disturb load 2's rendered state.
        var state = SurfaceLoadState()
        let slowLoad = state.startLoading()
        let retryLoad = state.startLoading()
        state.loadError = "retry failed"
        state.finishLoading(generation: retryLoad)
        state.finishLoading(generation: slowLoad)
        #expect(!state.isLoading)
        #expect(state.loadError == "retry failed")
    }

    @Test func restartClearsThePreviousFailure() {
        var state = SurfaceLoadState()
        let failed = state.startLoading()
        state.finishLoading(generation: failed)
        state.loadError = "previous failure"
        _ = state.startLoading()
        #expect(state.isLoading)
        #expect(state.loadError == nil)
    }
}
