import Foundation
import SwiftUI
import Testing
@testable import CupThreadFeedback

// MARK: - Reload failure presentation (issue #534)

/// A failed refresh must never wipe the rendered changelog. With entries on
/// screen the failure becomes the transient inline notice and the entries
/// stay; only a failure with nothing to show fills the surface with the
/// full-screen error (the #59 invariant, shared with the list and board via
/// `SearchReloadOutcome`).
@Suite("WhatsNewView Reload Notice Tests", .serialized)
struct WhatsNewViewReloadNoticeTests {
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

    @Test func cancelledRefreshPreservesEntriesAndRetryCanFail() {
        let entries = [makeEntry()]
        var state = WhatsNewViewState(entries: entries, isLoading: false, hasLoadedOnce: true)
        let cancelled = state.startLoading()
        state.handleFailure(error: CancellationError(), generation: cancelled)
        state.finishLoading(generation: cancelled, wasCancelled: true)
        #expect(state.entries == entries)
        #expect(state.hasLoadedOnce)
        #expect(state.isLoading)
        #expect(state.loadError == nil)
        #expect(state.reloadNotice == nil)

        // A failed retry keeps the entries on screen and surfaces the failure
        // as the transient reload notice (issue #534).
        let retry = state.startLoading()
        let failure = URLError(.timedOut)
        state.handleFailure(error: failure, generation: retry)
        state.finishLoading(generation: retry)
        #expect(!state.isLoading)
        #expect(state.loadError == nil)
        #expect(state.reloadNotice == FriendlyError.message(for: failure))
        #expect(state.entries == entries)
    }

    @Test func reloadFailureWithEntriesPreservesContentAndSetsNotice() {
        let entries = [
            makeEntry(id: "e1", title: "Version 1.0"),
            makeEntry(id: "e2", title: "Version 2.0")
        ]
        var state = WhatsNewViewState(entries: entries, isLoading: false, hasLoadedOnce: true)
        let generation = state.startLoading()
        let failure = URLError(.notConnectedToInternet)

        state.handleFailure(error: failure, generation: generation)
        state.finishLoading(generation: generation)

        #expect(state.entries == entries)
        #expect(state.hasLoadedOnce)
        #expect(!state.isLoading)
        #expect(state.loadError == nil)
        #expect(state.reloadNotice == FriendlyError.message(for: failure))
    }

    @Test func reloadRateLimitUsesTheSharedRateLimitedNotice() {
        var state = WhatsNewViewState(entries: [makeEntry()], isLoading: false, hasLoadedOnce: true)
        let generation = state.startLoading()

        state.handleFailure(
            error: FeedbackClientError.rateLimited(message: "Too many requests.", requestId: nil),
            generation: generation
        )
        state.finishLoading(generation: generation)

        #expect(state.loadError == nil)
        #expect(state.reloadNotice == CupThreadStrings.tr("cupthread.search.rate_limited"))
        #expect(state.entries.count == 1)
    }

    @Test func firstLoadFailureUsesFullScreenError() {
        var state = WhatsNewViewState()
        let generation = state.startLoading()
        let failure = URLError(.timedOut)

        state.handleFailure(error: failure, generation: generation)
        state.finishLoading(generation: generation)

        #expect(state.loadError == FriendlyError.message(for: failure))
        #expect(state.reloadNotice == nil)
        #expect(state.entries.isEmpty)
    }

    @Test func reloadFailureOnLoadedEmptySurfaceUsesFullScreenError() {
        var state = WhatsNewViewState(entries: [], isLoading: false, hasLoadedOnce: true)
        let generation = state.startLoading()
        let failure = URLError(.timedOut)

        state.handleFailure(error: failure, generation: generation)
        state.finishLoading(generation: generation)

        #expect(state.loadError == FriendlyError.message(for: failure))
        #expect(state.reloadNotice == nil)
    }

    @Test func cancelledReloadWritesNoNotice() {
        let entries = [makeEntry()]
        var state = WhatsNewViewState(entries: entries, isLoading: false, hasLoadedOnce: true)
        let generation = state.startLoading()

        state.handleFailure(error: URLError(.cancelled), generation: generation)
        state.finishLoading(generation: generation, wasCancelled: true)

        #expect(state.reloadNotice == nil)
        #expect(state.loadError == nil)
        #expect(state.entries == entries)
    }

    @Test func newLoadCycleClearsAReloadNotice() {
        var state = WhatsNewViewState(entries: [makeEntry()], isLoading: false, hasLoadedOnce: true)
        let failed = state.startLoading()
        state.handleFailure(error: URLError(.timedOut), generation: failed)
        state.finishLoading(generation: failed)
        #expect(state.reloadNotice != nil)

        state.startLoading()

        #expect(state.reloadNotice == nil)
    }

    @Test func successfulReloadClearsAReloadNotice() {
        var state = WhatsNewViewState(entries: [makeEntry()], isLoading: false, hasLoadedOnce: true)
        let failed = state.startLoading()
        state.handleFailure(error: URLError(.timedOut), generation: failed)
        state.finishLoading(generation: failed)
        #expect(state.reloadNotice != nil)

        let retry = state.startLoading()
        let refreshed = [makeEntry(id: "e2", title: "Version 2.0")]
        state.handleSuccess(entries: refreshed, generation: retry)
        state.finishLoading(generation: retry)

        #expect(state.reloadNotice == nil)
        #expect(state.loadError == nil)
        #expect(state.entries == refreshed)
    }

    @Test func permissionDenialClearsAReloadNotice() {
        var state = WhatsNewViewState(entries: [makeEntry()], isLoading: false, hasLoadedOnce: true)
        let failed = state.startLoading()
        state.handleFailure(error: URLError(.timedOut), generation: failed)
        state.finishLoading(generation: failed)
        #expect(state.reloadNotice != nil)

        state.handlePermissionDenied(generation: state.loadGeneration)

        #expect(state.reloadNotice == nil)
        #expect(state.loadError == nil)
    }

    @Test func staleFailureCannotWriteAReloadNotice() {
        var state = WhatsNewViewState(entries: [makeEntry()], isLoading: false, hasLoadedOnce: true)
        let stale = state.startLoading()
        state.startLoading()

        state.handleFailure(error: URLError(.timedOut), generation: stale)

        #expect(state.reloadNotice == nil)
        #expect(state.loadError == nil)
    }

    // MARK: - Rendering with a notice

    @Test @MainActor func whatsNewViewKeepsEntriesAndShowsNoticeOnFailedRefresh() {
        let client = makeTestClient()
        let entries = [makeEntry(id: "e1", title: "Version 1.0")]
        let view = WhatsNewView(
            client: client,
            userToken: "3c5f7a9e-1b2d-4e8f-9a0b-2c3d4e5f6a7b",
            state: WhatsNewViewState(
                entries: entries,
                isLoading: false,
                hasLoadedOnce: true,
                reloadNotice: "Network connection lost"
            )
        )

        _ = view.body
        #expect(view.entries.count == 1)
        #expect(view.loadError == nil)
        #expect(view.reloadNotice == "Network connection lost")
    }

    @Test @MainActor func whatsNewViewUsesFullScreenErrorOnFreshFailure() {
        let client = makeTestClient()
        let view = WhatsNewView(
            client: client,
            userToken: "3c5f7a9e-1b2d-4e8f-9a0b-2c3d4e5f6a7b",
            state: WhatsNewViewState(
                isLoading: false,
                hasLoadedOnce: false,
                loadError: "Network connection lost"
            )
        )

        _ = view.body
        #expect(view.entries.isEmpty)
        #expect(view.loadError == "Network connection lost")
        #expect(view.reloadNotice == nil)
    }

    // MARK: - Failed refresh lifecycle

    /// A failed refresh must reach `WhatsNewViewState.handleFailure` and must
    /// not short-circuit the surface: the next refresh still issues a request
    /// and can recover. The state-level tests above pin the presentation
    /// split (entries preserved + notice vs. full-screen error); this test
    /// pins the view's load lifecycle across the failure.
    @Test @MainActor func whatsNewViewRetriesAfterAFailedRefresh() async throws {
        let apiHost = "whatsnew-refresh.example.com"
        let client = makeClient(
            baseURL: URL(string: "https://\(apiHost)")!,
            appKey: "app_whatsnew_refresh_test"
        )
        let requestCounter = CaptureBox<Int>()
        requestCounter.value = 0

        let payload: [String: Any] = [
            "entries": [
                [
                    "id": "e_refresh",
                    "title": "Version 1.0",
                    "body": "Release notes",
                    "versionLabel": "1.0.0",
                    "publishedAt": "2026-01-01T00:00:00.000Z",
                    "linkedRequests": []
                ]
            ],
            "hasMore": false
        ]

        MockURLProtocol.setHandler(forHost: apiHost) { _ in
            let count = (requestCounter.value ?? 0) + 1
            requestCounter.value = count
            switch count {
            case 1, 3:
                return (makeHTTPResponse(), try encodeJSON(payload))
            default:
                throw URLError(.notConnectedToInternet)
            }
        }
        defer { MockURLProtocol.setHandler(forHost: apiHost, nil) }

        let view = WhatsNewView(
            client: client,
            userToken: "3c5f7a9e-1b2d-4e8f-9a0b-2c3d4e5f6a7b",
            state: WhatsNewViewState()
        )

        await view.loadEntries()
        #expect(requestCounter.value == 1)

        // The offline refresh fails but leaves the surface able to retry.
        await view.loadEntries()
        #expect(requestCounter.value == 2)

        await view.loadEntries()
        #expect(requestCounter.value == 3)
    }
}
