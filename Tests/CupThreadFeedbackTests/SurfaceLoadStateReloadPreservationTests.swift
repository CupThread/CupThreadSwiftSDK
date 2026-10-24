import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - SurfaceLoadState reload preservation (issue #545)

/// The #59/#534 preserve-content invariant, extended to the
/// ``SurfaceLoadState`` surfaces (``CommentsView``, ``UserProfileView``):
/// a failed reload with content on screen becomes the transient reload
/// notice and keeps the content authoritative; only a failure with nothing
/// to show fills the surface with the full-screen error. A successful load
/// pins `hasLoadedOnce` so the loading branch can never reclaim a surface
/// that already rendered content.
@Suite("SurfaceLoadState Reload Preservation")
struct SurfaceLoadStateReloadPreservationTests {
    // MARK: Success path

    @Test func successfulLoadPinsHasLoadedOnceAndRetiresTheNotice() {
        var state = SurfaceLoadState()
        state.reloadNotice = "stale failure"
        let generation = state.startLoading()

        state.recordSuccess(generation: generation)

        #expect(state.hasLoadedOnce)
        #expect(state.reloadNotice == nil)
        #expect(state.loadError == nil)
    }

    @Test func supersededSuccessCannotPinHasLoadedOnce() {
        var state = SurfaceLoadState()
        let stale = state.startLoading()
        state.startLoading()

        state.recordSuccess(generation: stale)

        #expect(!state.hasLoadedOnce)
    }

    // MARK: Failure path — the #59/#534 decision shape

    @Test func reloadFailureWithContentSetsNoticeAndKeepsTheContentMarker() {
        var state = SurfaceLoadState(isLoading: false, hasLoadedOnce: true)
        let generation = state.startLoading()
        let failure = URLError(.notConnectedToInternet)

        state.handleFailure(error: failure, generation: generation, hasExistingContent: true)
        state.finishLoading(generation: generation)

        #expect(!state.isLoading)
        #expect(state.hasLoadedOnce)
        #expect(state.loadError == nil)
        #expect(state.reloadNotice == FriendlyError.message(for: failure))
    }

    @Test func reloadFailureWithoutContentUsesFullScreenError() {
        // A loaded-but-empty thread (hasLoadedOnce, no rows) has nothing to
        // preserve: the full-screen error owns the surface, matching
        // `SearchReloadOutcome`'s "nothing to show" branch.
        var state = SurfaceLoadState(isLoading: false, hasLoadedOnce: true)
        let generation = state.startLoading()
        let failure = URLError(.timedOut)

        state.handleFailure(error: failure, generation: generation, hasExistingContent: false)

        #expect(state.loadError == FriendlyError.message(for: failure))
        #expect(state.reloadNotice == nil)
        #expect(state.hasLoadedOnce, "a failed reload never unpins the loaded marker")
    }

    @Test func firstLoadFailureUsesFullScreenError() {
        var state = SurfaceLoadState()
        let generation = state.startLoading()

        state.handleFailure(error: URLError(.timedOut), generation: generation, hasExistingContent: false)

        #expect(state.loadError != nil)
        #expect(state.reloadNotice == nil)
        #expect(!state.hasLoadedOnce)
    }

    @Test func rateLimitedFailureUsesFriendlyCopyNotSearchCopy() {
        var state = SurfaceLoadState(isLoading: false, hasLoadedOnce: true)
        let generation = state.startLoading()
        let failure = FeedbackClientError.rateLimited(message: "Too many requests.", requestId: nil)

        state.handleFailure(error: failure, generation: generation, hasExistingContent: true)

        // `SurfaceLoadState.handleFailure` maps through FriendlyError so the
        // search surface's 429 copy never leaks into these surfaces.
        #expect(state.reloadNotice == FriendlyError.message(for: failure))
        #expect(state.reloadNotice != CupThreadStrings.tr("cupthread.search.rate_limited"))
    }

    @Test func cancellationWritesNoVerdict() {
        var state = SurfaceLoadState(isLoading: false, hasLoadedOnce: true)
        let generation = state.startLoading()

        state.handleFailure(error: CancellationError(), generation: generation, hasExistingContent: true)
        state.handleFailure(error: URLError(.cancelled), generation: generation, hasExistingContent: true)

        #expect(state.loadError == nil)
        #expect(state.reloadNotice == nil)
    }

    @Test func staleFailureWritesNoVerdict() {
        var state = SurfaceLoadState(isLoading: false, hasLoadedOnce: true)
        let stale = state.startLoading()
        state.startLoading()

        state.handleFailure(error: URLError(.timedOut), generation: stale, hasExistingContent: true)

        #expect(state.loadError == nil)
        #expect(state.reloadNotice == nil)
    }

    // MARK: Notice lifecycle

    @Test func startLoadingClearsAReloadNoticeWithoutUnpinningTheMarker() {
        var state = SurfaceLoadState(isLoading: false, hasLoadedOnce: true)
        state.reloadNotice = "previous failure"

        _ = state.startLoading()

        #expect(state.reloadNotice == nil)
        #expect(state.hasLoadedOnce)
    }

    @Test func successfulReloadRetiresTheNotice() {
        var state = SurfaceLoadState(isLoading: false, hasLoadedOnce: true)
        let failed = state.startLoading()
        state.handleFailure(error: URLError(.timedOut), generation: failed, hasExistingContent: true)
        #expect(state.reloadNotice != nil)

        let retry = state.startLoading()
        state.recordSuccess(generation: retry)
        state.finishLoading(generation: retry)

        #expect(state.reloadNotice == nil)
        #expect(state.loadError == nil)
        #expect(state.hasLoadedOnce)
        #expect(!state.isLoading)
    }
}
