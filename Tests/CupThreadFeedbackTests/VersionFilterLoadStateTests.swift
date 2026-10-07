import Foundation
import SwiftUI
import Testing
@testable import CupThreadFeedback

/// Issue #285 (BUG-20): the version-filter options load used a bare `try?`,
/// so any failure — offline, 5xx, 429, permission denial — collapsed into an
/// empty list and silently disabled "Filter by version" for the whole
/// presentation. These tests pin the replacement contract: failures are
/// classified and retryable, and only a *successful* empty server list
/// disables the menu.
@Suite("VersionFilterLoadState and VersionFilterMenu", .serialized)
struct VersionFilterLoadStateTests {
    static let apiHost = "version-filter.example.com"

    // MARK: - Helpers

    private func makeAPIClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!)
    }

    private func makeVersion(id: String, label: String, position: Int = 0) throws -> AppVersion {
        try JSONDecoder().decode(
            AppVersion.self,
            from: encodeJSON([
                "id": id,
                "appId": "app-1",
                "label": label,
                "position": position,
                "released": true,
                "releasedAt": NSNull(),
                "description": NSNull(),
                "createdAt": "2026-01-01T00:00:00.000Z",
                "updatedAt": "2026-01-01T00:00:00.000Z"
            ])
        )
    }

    /// Runs one full load cycle against the stubbed session, exactly the way
    /// `FeatureRequestsView.loadVersions()` drives the state.
    private func performLoad(
        into state: inout VersionFilterLoadState,
        client: FeedbackClient
    ) async {
        state.loadStarted()
        do {
            state.loadFinished(try await client.fetchVersions())
        } catch {
            state.loadFailed(error)
        }
    }

    // MARK: - Successful load

    @Test func successfulLoadPopulatesVersionsAndKeepsMenuEnabled() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 200),
                try encodeJSON(["versions": [
                    ["id": "ver-1", "appId": "app-1", "label": "2.1", "position": 0,
                     "released": true, "releasedAt": NSNull(), "description": NSNull(),
                     "createdAt": "2026-01-01T00:00:00.000Z", "updatedAt": "2026-01-01T00:00:00.000Z"],
                    ["id": "ver-2", "appId": "app-1", "label": "2.2", "position": 1,
                     "released": false, "releasedAt": NSNull(), "description": NSNull(),
                     "createdAt": "2026-01-01T00:00:00.000Z", "updatedAt": "2026-01-01T00:00:00.000Z"]
                ]])
            )
        }

        var state = VersionFilterLoadState()
        await performLoad(into: &state, client: makeAPIClient())

        #expect(state.versions.map(\.label) == ["2.1", "2.2"])
        #expect(state.errorMessage == nil)
        #expect(!state.isLoading)
        #expect(!state.isMenuDisabled)
    }

    @Test func successfulEmptyServerListDisablesMenuSilently() {
        var state = VersionFilterLoadState()
        state.loadStarted()
        state.loadFinished([])

        #expect(state.versions.isEmpty)
        #expect(state.errorMessage == nil)
        #expect(state.isMenuDisabled, "A successful empty list means 'no versions configured' and stays silent-disabled")
    }

    // MARK: - Classified failures stay retryable (issue #285 requirement 1)

    @Test func rateLimitedVersionsLoadSurfacesErrorAndKeepsMenuEnabled() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 429),
                try encodeJSON(["error": "Too many requests"])
            )
        }

        var state = VersionFilterLoadState()
        await performLoad(into: &state, client: makeAPIClient())

        let expected = FeedbackClientError.rateLimited(message: "Too many requests", requestId: nil)
        #expect(state.versions.isEmpty)
        #expect(state.errorMessage != nil)
        #expect(state.errorMessage == FriendlyError.message(for: expected))
        #expect(!state.isMenuDisabled, "A failed load must keep the retry affordance reachable")
    }

    @Test func serverErrorVersionsLoadSurfacesErrorAndKeepsMenuEnabled() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 500),
                try encodeJSON(["error": "Internal Server Error", "code": "internal_error"])
            )
        }

        var state = VersionFilterLoadState()
        await performLoad(into: &state, client: makeAPIClient())

        #expect(state.versions.isEmpty)
        #expect(state.errorMessage != nil)
        #expect(!state.isMenuDisabled)
    }

    @Test func offlineVersionsLoadSurfacesErrorAndKeepsMenuEnabled() {
        var state = VersionFilterLoadState()
        state.loadStarted()
        state.loadFailed(URLError(.notConnectedToInternet))

        #expect(state.versions.isEmpty)
        #expect(state.errorMessage == CupThreadStrings.tr("cupthread.error.offline"))
        #expect(!state.isMenuDisabled)
    }

    // MARK: - Cancellation (issue #285 requirement 3)

    @Test func cancelledLoadLeavesVersionsAndErrorStateUntouched() {
        var state = VersionFilterLoadState()
        state.loadStarted()
        state.loadFailed(URLError(.cancelled))

        #expect(state.versions.isEmpty)
        #expect(state.errorMessage == nil, "A cancelled load presents no error the user cannot act on")
        #expect(!state.isLoading)
    }

    @Test func cancellationErrorTypeAlsoStaysSilent() {
        var state = VersionFilterLoadState()
        state.loadStarted()
        state.loadFailed(CancellationError())

        #expect(state.errorMessage == nil)
        #expect(state.versions.isEmpty)
    }

    // MARK: - Retry cycle (issue #285 requirements 1-2)

    @Test func retryAfterFailureClearsErrorAndPopulatesVersions() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 500),
                try encodeJSON(["error": "Internal Server Error", "code": "internal_error"])
            )
        }

        var state = VersionFilterLoadState()
        await performLoad(into: &state, client: makeAPIClient())
        #expect(state.errorMessage != nil)

        // The retry re-points the handler at a successful response: exactly
        // one fetch per retry, and success clears the failure state.
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 200),
                try encodeJSON(["versions": [
                    ["id": "ver-1", "appId": "app-1", "label": "2.1", "position": 0,
                     "released": true, "releasedAt": NSNull(), "description": NSNull(),
                     "createdAt": "2026-01-01T00:00:00.000Z", "updatedAt": "2026-01-01T00:00:00.000Z"]
                ]])
            )
        }
        await performLoad(into: &state, client: makeAPIClient())

        #expect(state.versions.map(\.label) == ["2.1"])
        #expect(state.errorMessage == nil)
        #expect(!state.isMenuDisabled)
    }

    @Test func failedRetryKeepsFreshErrorCopyInsteadOfStackingAttempts() {
        var state = VersionFilterLoadState()
        state.loadStarted()
        state.loadFailed(URLError(.timedOut))
        let firstMessage = state.errorMessage

        state.loadStarted()
        state.loadFailed(URLError(.notConnectedToInternet))

        #expect(firstMessage == CupThreadStrings.tr("cupthread.error.timed_out"))
        #expect(state.errorMessage == CupThreadStrings.tr("cupthread.error.offline"))
        #expect(!state.isMenuDisabled)
    }

    // MARK: - VersionFilterMenu presentation (issue #285 requirement 4)

    @Test @MainActor func menuRendersAndStaysEnabledForEveryFailureState() throws {
        var failed = VersionFilterLoadState()
        failed.loadStarted()
        failed.loadFailed(URLError(.notConnectedToInternet))

        let retryable = VersionFilterMenu(
            selectedVersionID: .constant(nil),
            state: failed,
            onRetry: {}
        )
        _ = retryable.body
        #expect(!failed.isMenuDisabled, "Failed load: menu must stay enabled so retry is reachable")

        let loading = VersionFilterMenu(
            selectedVersionID: .constant(nil),
            state: VersionFilterLoadState(isLoading: true),
            onRetry: {}
        )
        _ = loading.body
        #expect(loading.state.isMenuDisabled, "In-flight first load: no verdict yet, transient disable matches the pre-fix behavior")

        let configured = VersionFilterMenu(
            selectedVersionID: .constant(nil),
            state: VersionFilterLoadState(versions: [try makeVersion(id: "ver-1", label: "2.1")]),
            onRetry: {}
        )
        _ = configured.body
        #expect(!configured.state.isMenuDisabled)

        let empty = VersionFilterMenu(
            selectedVersionID: .constant(nil),
            state: VersionFilterLoadState(),
            onRetry: {}
        )
        _ = empty.body
        #expect(empty.state.isMenuDisabled, "Successful empty list: menu disabled exactly as before the fix")
    }

    @Test @MainActor func menuRetryInvokesCallbackExactlyOncePerTap() {
        var retryCount = 0
        var failed = VersionFilterLoadState()
        failed.loadStarted()
        failed.loadFailed(URLError(.notConnectedToInternet))

        let menu = VersionFilterMenu(
            selectedVersionID: .constant(nil),
            state: failed,
            onRetry: { retryCount += 1 }
        )
        _ = menu.body

        menu.onRetry()
        #expect(retryCount == 1)
    }
}
