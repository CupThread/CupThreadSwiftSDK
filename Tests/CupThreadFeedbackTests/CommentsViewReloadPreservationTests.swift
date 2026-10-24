import Foundation
import SwiftUI
import Testing
@testable import CupThreadFeedback

// MARK: - CommentsView reload preservation (issue #545)

/// Pull-to-refresh on a populated thread must never collapse the rendered
/// comments to a bare spinner, and a failed refresh must never replace them
/// with the full-screen error — the #59/#534 preserve-content invariant
/// extended to the `SurfaceLoadState` surfaces. The issue additionally
/// requires the submit path to survive a refresh resolving behind it, so the
/// locally appended comment is pinned through `reconcilingLocallyPostedComments`.
@Suite("CommentsView Reload Preservation")
struct CommentsViewReloadPreservationTests {
    // MARK: - Body branch order (source-scan)

    /// The loading branch owns the surface only before the first successful
    /// load; a reload in flight over rendered comments must not fall into it.
    @Test func loadingBranchRequiresNoSuccessfulLoadYet() throws {
        let content = try String(
            contentsOf: try #require(Self.commentsViewSourceURL()),
            encoding: .utf8
        )

        let loadingBranch = try #require(
            content.range(of: "loadState.isLoading && !loadState.hasLoadedOnce"),
            "the loading branch must require `!hasLoadedOnce` so a reload never collapses rendered comments to a spinner (issue #545)"
        )
        // A comment appended by `submitComment` before any load succeeded must
        // also keep the spinner away: `hasLoadedOnce` is still false on that
        // path, so the branch additionally requires an empty thread.
        let spinner = try #require(
            content.range(of: "ProgressView()", range: loadingBranch.upperBound..<content.endIndex)
        )
        #expect(
            content[loadingBranch.upperBound..<spinner.lowerBound].contains("comments.isEmpty"),
            "the loading branch must render only when there is nothing to preserve (issue #545)"
        )
        let fullScreenError = try #require(
            content.range(of: "LoadErrorView(message: loadError)", range: loadingBranch.upperBound..<content.endIndex)
        )
        // The full-screen error branch is gated on an empty thread: a failure
        // with comments on screen falls through to the content rows instead.
        let branchCondition = content[loadingBranch.upperBound..<fullScreenError.lowerBound]
        #expect(
            branchCondition.contains("comments.isEmpty"),
            "LoadErrorView must own the surface only when there is nothing to show (issue #545)"
        )
    }

    /// The failed-refresh notice renders as the inline banner overlay, the
    /// local precedent from WhatsNewView (#534).
    @Test func failureNoticeOverlaysRenderedComments() throws {
        let content = try String(
            contentsOf: try #require(Self.commentsViewSourceURL()),
            encoding: .utf8
        )

        let overlay = try #require(
            content.range(of: ".overlay(alignment: .top)"),
            "the reload failure must surface as the transient top banner (issue #545)"
        )
        let overlayBody = content[overlay.lowerBound..<content.endIndex]
        #expect(overlayBody.contains("loadState.reloadNotice"))
        #expect(overlayBody.contains("InlineNoticeBanner(message: reloadNotice)"))
    }

    /// The submit/load coordination must be wired into the load and submit
    /// paths (the pure merge semantics are pinned by the helper tests below;
    /// `@State` writes are not observable on a unit-constructed view, so the
    /// wiring is pinned with the established source-scan pattern).
    @Test func loadAndSubmitPathsCoordinateThroughTheMerge() throws {
        let content = try String(
            contentsOf: try #require(Self.commentsViewSourceURL()),
            encoding: .utf8
        )

        let append = try #require(
            content.range(of: "comments.append(newComment)"),
            "the append anchor was renamed; update this scan"
        )
        let tracking = content[append.upperBound..<content.endIndex]
        #expect(
            tracking.contains("locallyPostedCommentIDs.insert(newComment.id)"),
            "a successful submit must track the appended row until the server echoes it (issue #545)"
        )

        let fetch = try #require(
            content.range(of: "client.fetchComments(featureRequestId: featureRequestId)"),
            "the fetch anchor was renamed; update this scan"
        )
        let successPath = content[fetch.upperBound..<content.endIndex]
        #expect(
            successPath.contains("reconcilingLocallyPostedComments("),
            "a successful load must reconcile locally posted comments against the fetched page (issue #545)"
        )
        #expect(
            successPath.contains("loadState.recordSuccess(generation: generation)"),
            "a successful load must pin hasLoadedOnce so the loading branch cannot reclaim the surface (issue #545)"
        )
        #expect(
            successPath.contains("hasExistingContent: !comments.isEmpty"),
            "a load failure must preserve already-rendered comments via the inline notice (issue #545)"
        )
    }

    // MARK: - Rendering with seeded state

    private static func makeComment(
        id: String,
        body: String = "Body",
        createdAt: String = "2026-01-01T00:00:00.000Z"
    ) -> FeatureRequestComment {
        FeatureRequestComment(
            id: id,
            featureRequestId: "fr_545",
            body: body,
            createdAt: createdAt
        )
    }

    @Test @MainActor func populatedThreadSurvivesARefreshInProgressWithoutASpinner() {
        let view = CommentsView(
            client: makeClient(),
            userToken: "token_545",
            featureRequestId: "fr_545",
            featureRequestTitle: "Title",
            preResolvedAuthentication: true,
            initialComments: [
                Self.makeComment(id: "c-1"),
                Self.makeComment(id: "c-2")
            ],
            initialLoadState: SurfaceLoadState(isLoading: true, hasLoadedOnce: true)
        )

        _ = view.body
        #expect(view.isLoading)
        #expect(view.hasLoadedOnce)
        #expect(view.renderedComments.count == 2)
        // The reload never reclaims the surface: no spinner frame exists in
        // the rendered tree while comments are on screen (issue #545).
        #expect(!viewTreeContains(view.body, ProgressView<EmptyView, EmptyView>.self))
    }

    @Test @MainActor func populatedThreadWithAFailedRefreshKeepsCommentsAndShowsTheNotice() {
        let view = CommentsView(
            client: makeClient(),
            userToken: "token_545",
            featureRequestId: "fr_545",
            featureRequestTitle: "Title",
            preResolvedAuthentication: true,
            initialComments: [Self.makeComment(id: "c-1")],
            initialLoadState: SurfaceLoadState(
                isLoading: false,
                hasLoadedOnce: true,
                loadError: nil,
                reloadNotice: "Network connection lost"
            )
        )

        _ = view.body
        #expect(view.renderedComments.count == 1)
        #expect(view.loadError == nil, "a failure with content on screen must not write the full-screen verdict")
        #expect(view.reloadNotice == "Network connection lost")
        #expect(!viewTreeContains(view.body, LoadErrorView.self))
    }

    @Test @MainActor func firstLoadFailureStillUsesFullScreenError() {
        // No regression of the empty case: a first-load failure has nothing
        // to preserve and fills the surface with the full-screen error.
        let view = CommentsView(
            client: makeClient(),
            userToken: "token_545",
            featureRequestId: "fr_545",
            featureRequestTitle: "Title",
            preResolvedAuthentication: true,
            initialComments: [],
            initialLoadState: SurfaceLoadState(
                isLoading: false,
                hasLoadedOnce: false,
                loadError: "Network connection lost"
            )
        )

        _ = view.body
        #expect(view.loadError == "Network connection lost")
        #expect(view.reloadNotice == nil)
        #expect(viewTreeContains(view.body, LoadErrorView.self))
    }

    @Test @MainActor func firstLoadInProgressStillShowsTheSpinner() {
        let view = CommentsView(
            client: makeClient(),
            userToken: "token_545",
            featureRequestId: "fr_545",
            featureRequestTitle: "Title",
            preResolvedAuthentication: true
        )

        _ = view.body
        #expect(view.isLoading)
        #expect(!view.hasLoadedOnce)
        #expect(viewTreeContains(view.body, ProgressView<EmptyView, EmptyView>.self))
    }

    /// A comment posted after a failed first load is rendered content even
    /// though no load has succeeded yet; a pull-to-refresh must not swap it
    /// for the first-load spinner (CodeRabbit finding on PR #546).
    @Test @MainActor func locallyPostedCommentBeforeFirstSuccessfulLoadSurvivesARefresh() {
        let view = CommentsView(
            client: makeClient(),
            userToken: "token_545",
            featureRequestId: "fr_545",
            featureRequestTitle: "Title",
            preResolvedAuthentication: true,
            initialComments: [Self.makeComment(id: "c-new", body: "Just posted")],
            initialLoadState: SurfaceLoadState(isLoading: true, hasLoadedOnce: false)
        )

        _ = view.body
        #expect(view.isLoading)
        #expect(!view.hasLoadedOnce)
        #expect(view.renderedComments.map(\.id) == ["c-new"])
        #expect(!viewTreeContains(view.body, ProgressView<EmptyView, EmptyView>.self))
    }

    // MARK: - Failed-refresh lifecycle

    /// A failed refresh must not short-circuit the surface: the retry still
    /// issues a request and recovers, mirroring the WhatsNewView lifecycle
    /// pin from #534.
    @Test @MainActor func failedRefreshKeepsTheThreadRetryableAndRecoverable() async throws {
        let apiHost = "comments-refresh-545.test.example.com"
        let requestCounter = CaptureBox<Int>()
        requestCounter.value = 0

        let payload: [String: Any] = [
            "comments": [[
                "id": "c-545",
                "featureRequestId": "fr_545",
                "body": "Survives the failed refresh",
                "authorName": NSNull(),
                "createdAt": "2026-01-01T00:00:00.000Z"
            ]],
            "total": 1,
            "hasMore": false
        ]

        MockURLProtocol.setHandler(forHost: apiHost) { request in
            let count = (requestCounter.value ?? 0) + 1
            requestCounter.value = count
            if count == 2 {
                throw URLError(.notConnectedToInternet)
            }
            #expect(request.url?.path == "/api/v1/feature-requests/fr_545/comments")
            return (makeHTTPResponse(), try encodeJSON(payload))
        }
        defer { MockURLProtocol.setHandler(forHost: apiHost, nil) }

        let view = CommentsView(
            client: makeClient(baseURL: URL(string: "https://\(apiHost)")!),
            userToken: "token_545",
            featureRequestId: "fr_545",
            featureRequestTitle: "Title",
            preResolvedAuthentication: true
        )

        await view.loadComments() // initial load succeeds
        await view.loadComments() // refresh fails
        await view.loadComments() // retry recovers

        let requests = try #require(requestCounter.value)
        #expect(requests == 3, "the failed refresh must not lock the surface out of further loads")
    }

    // MARK: - Submit/refresh interleave (issue #545, third failure scenario)

    /// A refresh whose page was produced before a POST resolved cannot
    /// contain the just-posted comment: the merge re-appends it and keeps it
    /// tracked until the server echoes it.
    @Test func refreshPageMissingTheLocallyPostedCommentPreservesIt() {
        let fetched = [Self.makeComment(id: "c-1", body: "Server row")]
        let current = [
            Self.makeComment(id: "c-1", body: "Server row"),
            Self.makeComment(id: "c-new", body: "Just posted")
        ]

        let reconciliation = CommentsView.reconcilingLocallyPostedComments(
            fetched,
            current: current,
            locallyPostedIDs: ["c-new"]
        )

        #expect(reconciliation.merged.map(\.id) == ["c-1", "c-new"])
        #expect(reconciliation.remainingIDs == ["c-new"])
    }

    /// Once the server echoes the locally posted comment, the fetched page's
    /// ordering wins and the tracking set retires the id — so a later page
    /// omitting it (moderation, deletion) propagates normally.
    @Test func refreshPageEchoingTheLocallyPostedCommentReconcilesTheTracking() {
        let fetched = [
            Self.makeComment(id: "c-1"),
            Self.makeComment(id: "c-new", createdAt: "2026-01-02T00:00:00.000Z")
        ]
        let current = [
            Self.makeComment(id: "c-1"),
            Self.makeComment(id: "c-new", createdAt: "2026-01-02T00:00:00.000Z")
        ]

        let reconciliation = CommentsView.reconcilingLocallyPostedComments(
            fetched,
            current: current,
            locallyPostedIDs: ["c-new"]
        )

        #expect(reconciliation.merged.map(\.id) == ["c-1", "c-new"])
        #expect(reconciliation.remainingIDs.isEmpty)
    }

    /// Without locally posted rows the refresh is the plain overwrite it has
    /// always been — moderation removals must keep propagating.
    @Test func refreshWithoutLocallyPostedCommentsIsAPlainOverwrite() {
        let fetched = [Self.makeComment(id: "c-1")]
        let current = [Self.makeComment(id: "c-moderated", body: "Removed server-side")]

        let reconciliation = CommentsView.reconcilingLocallyPostedComments(
            fetched,
            current: current,
            locallyPostedIDs: []
        )

        #expect(reconciliation.merged.map(\.id) == ["c-1"])
        #expect(reconciliation.remainingIDs.isEmpty)
    }

    /// Multiple locally posted rows keep their local append order behind the
    /// fetched page, and only the still-unechoed ones stay tracked.
    @Test func multipleLocallyPostedCommentsPreserveTheirLocalOrder() {
        let fetched = [Self.makeComment(id: "c-1"), Self.makeComment(id: "c-echoed")]
        let current = [
            Self.makeComment(id: "c-1"),
            Self.makeComment(id: "c-echoed"),
            Self.makeComment(id: "c-first-post"),
            Self.makeComment(id: "c-second-post")
        ]

        let reconciliation = CommentsView.reconcilingLocallyPostedComments(
            fetched,
            current: current,
            locallyPostedIDs: ["c-second-post", "c-echoed", "c-first-post"]
        )

        #expect(reconciliation.merged.map(\.id) == ["c-1", "c-echoed", "c-first-post", "c-second-post"])
        #expect(reconciliation.remainingIDs == ["c-first-post", "c-second-post"])
    }

    // MARK: - Fixtures

    private static func commentsViewSourceURL() -> URL? {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            directory.deleteLastPathComponent()
            let candidate = directory
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("CupThreadFeedback", isDirectory: true)
                .appendingPathComponent("CommentsView.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
