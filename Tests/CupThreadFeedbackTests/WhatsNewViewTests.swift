import Foundation
import SwiftUI
import Testing
@testable import CupThreadFeedback

@Suite("WhatsNewView and WhatsNewViewState Tests")
struct WhatsNewViewTests {
    private func makeEntry(id: String = "entry-1", title: String = "Version 1.0") -> ChangelogEntry {
        ChangelogEntry(
            id: id,
            title: title,
            body: "Release notes for \(title)",
            versionLabel: "1.0.0",
            publishedAt: "2026-01-01T00:00:00.000Z",
            linkedRequests: []
        )
    }

    private func makeTestClient() -> FeedbackClient {
        makeClient(appKey: "app_test_dummy_key_123456")
    }

    // MARK: - Concurrency & Cancellation Tests (Issue #196)

    @Test func cancelledLoadDoesNotSetHasLoadedOnce() {
        var state = WhatsNewViewState()
        let generation = state.startLoading()

        #expect(state.isLoading)
        #expect(!state.hasLoadedOnce)
        #expect(state.entries.isEmpty)
        #expect(state.loadError == nil)

        // Simulate task cancellation before fetchChangelog returns
        let cancellationError = URLError(.cancelled)
        state.handleFailure(error: cancellationError, generation: generation)
        state.finishLoading(generation: generation)

        // Verify hasLoadedOnce remains false, allowing skeletons to display on reload
        #expect(!state.hasLoadedOnce)
        #expect(!state.isLoading)
        #expect(state.loadError == nil)
        #expect(state.entries.isEmpty)

        // On next load attempt, skeletons will be shown because isLoading && !hasLoadedOnce
        let nextGen = state.startLoading()
        #expect(state.isLoading)
        #expect(!state.hasLoadedOnce)
        state.finishLoading(generation: nextGen)
    }

    @Test func cancellationErrorTypeDoesNotSetHasLoadedOnce() {
        var state = WhatsNewViewState()
        let generation = state.startLoading()

        let cancellationError = CancellationError()
        state.handleFailure(error: cancellationError, generation: generation)
        state.finishLoading(generation: generation)

        #expect(!state.hasLoadedOnce)
        #expect(!state.isLoading)
        #expect(state.loadError == nil)
    }

    @Test func outOfOrderChangelogFetchesDoNotOverwriteNewerData() {
        var state = WhatsNewViewState()

        // Fetch 1 started first
        let gen1 = state.startLoading()
        #expect(gen1 == 1)

        // Fetch 2 started second (e.g. pull to refresh while 1 was in flight)
        let gen2 = state.startLoading()
        #expect(gen2 == 2)
        #expect(state.isLoading)

        // Fetch 2 completed first
        let entries2 = [makeEntry(id: "e2", title: "Version 2.0 (New)")]
        state.handleSuccess(entries: entries2, generation: gen2)
        state.finishLoading(generation: gen2)

        #expect(state.entries == entries2)
        #expect(state.hasLoadedOnce)
        #expect(!state.isLoading)

        // Fetch 1 completed afterwards with older stale data
        let entries1 = [makeEntry(id: "e1", title: "Version 1.0 (Stale)")]
        state.handleSuccess(entries: entries1, generation: gen1)
        state.finishLoading(generation: gen1)

        // Assert that entries match fetch 2 and are not clobbered by fetch 1
        #expect(state.entries == entries2)
        #expect(state.hasLoadedOnce)
        #expect(!state.isLoading)
    }

    @Test func outOfOrderFailureDoesNotClobberNewerLoad() {
        var state = WhatsNewViewState()

        let gen1 = state.startLoading()
        let gen2 = state.startLoading()

        // Older generation failure should be discarded while gen2 is in flight
        state.handleFailure(error: URLError(.timedOut), generation: gen1)
        state.finishLoading(generation: gen1)

        #expect(state.loadError == nil)
        #expect(state.isLoading)

        // Newer generation succeeds
        let entries2 = [makeEntry(id: "e2", title: "Version 2.0")]
        state.handleSuccess(entries: entries2, generation: gen2)
        state.finishLoading(generation: gen2)

        #expect(state.entries == entries2)
        #expect(state.hasLoadedOnce)
        #expect(!state.isLoading)
        #expect(state.loadError == nil)
    }

    @Test func realLoadFailureSetsLoadErrorAndKeepsHasLoadedOnceFalse() {
        var state = WhatsNewViewState()
        let gen = state.startLoading()

        let networkError = URLError(.notConnectedToInternet)
        state.handleFailure(error: networkError, generation: gen)
        state.finishLoading(generation: gen)

        #expect(!state.hasLoadedOnce)
        #expect(!state.isLoading)
        #expect(state.loadError != nil)
        #expect(state.loadError == FriendlyError.message(for: networkError))
    }

    @Test func permissionDeniedMarksLoadedWithoutErrors() {
        var state = WhatsNewViewState()
        state.handlePermissionDenied()

        #expect(!state.isLoading)
        #expect(state.hasLoadedOnce)
        #expect(state.loadError == nil)
    }

    @Test func loadCycleIncrementsGenerationMonotonically() {
        var state = WhatsNewViewState()
        #expect(state.loadGeneration == 0)

        let g1 = state.startLoading()
        #expect(g1 == 1)
        #expect(state.loadGeneration == 1)

        let g2 = state.startLoading()
        #expect(g2 == 2)
        #expect(state.loadGeneration == 2)

        let g3 = state.startLoading()
        #expect(g3 == 3)
        #expect(state.loadGeneration == 3)
    }

    // MARK: - View Presentation Tests

    @Test @MainActor func whatsNewViewRendersSkeletonWhenLoadingAndNotLoadedOnce() {
        let client = makeTestClient()
        let view = WhatsNewView(
            client: client,
            userToken: "test_token",
            state: WhatsNewViewState(isLoading: true, hasLoadedOnce: false)
        )

        _ = view.body
        #expect(view.isLoading)
        #expect(!view.hasLoadedOnce)
        #expect(view.entries.isEmpty)
    }

    @Test @MainActor func whatsNewViewRendersEmptyStateWhenLoadedAndEntriesEmpty() {
        let client = makeTestClient()
        let view = WhatsNewView(
            client: client,
            userToken: "test_token",
            state: WhatsNewViewState(entries: [], isLoading: false, hasLoadedOnce: true)
        )

        _ = view.body
        #expect(!view.isLoading)
        #expect(view.hasLoadedOnce)
        #expect(view.entries.isEmpty)
    }

    @Test @MainActor func whatsNewViewRendersEntriesWhenLoadedWithEntries() {
        let client = makeTestClient()
        let entries = [
            makeEntry(id: "e1", title: "Version 1.0"),
            makeEntry(id: "e2", title: "Version 2.0")
        ]
        let view = WhatsNewView(
            client: client,
            userToken: "test_token",
            state: WhatsNewViewState(entries: entries, isLoading: false, hasLoadedOnce: true)
        )

        _ = view.body
        #expect(!view.isLoading)
        #expect(view.hasLoadedOnce)
        #expect(view.entries.count == 2)
    }

    @Test @MainActor func whatsNewViewRendersErrorWhenLoadErrorPresent() {
        let client = makeTestClient()
        let view = WhatsNewView(
            client: client,
            userToken: "test_token",
            state: WhatsNewViewState(
                isLoading: false,
                hasLoadedOnce: false,
                loadError: "Network connection lost"
            )
        )

        _ = view.body
        #expect(!view.isLoading)
        #expect(!view.hasLoadedOnce)
        #expect(view.loadError == "Network connection lost")
    }
}
