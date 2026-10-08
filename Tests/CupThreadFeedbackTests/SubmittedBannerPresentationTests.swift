import SwiftUI
import Testing
@testable import CupThreadFeedback

/// Issue #270 (BUG-14): the post-submit success banner lived inside
/// `cardScroll`'s populated-list branch only, so a post-submit reload that
/// came back empty replaced the confirmation with the "no results" state, and
/// tvOS's `tvList` never rendered the banner at all. The banner now composes
/// as a top overlay above both layouts through a shared helper; these tests
/// pin the helper's truth table and the empty-reload regression.
@Suite("FeatureRequestsView Submitted Banner Presentation")
struct SubmittedBannerPresentationTests {
    // MARK: - Helpers

    private func makeTestClient() -> FeedbackClient {
        makeClient(appKey: "app_test_dummy_key_123456")
    }

    private func makeResolvedLoadState() -> FeatureRequestsLoadState {
        var state = FeatureRequestsLoadState()
        let generation = state.startLoading()
        state.finishLoading(generation: generation, wasCancelled: false)
        return state
    }

    private func makeItem(id: String) -> FeatureRequestItem {
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

    /// Inspector-free structural check: recursively descends a static SwiftUI
    /// view tree (modifiers, conditional content, tuples) looking for a view
    /// of exactly `target`'s type.
    private func viewTreeContains(_ node: Any, _ target: Any.Type) -> Bool {
        if type(of: node) == target { return true }
        for child in Mirror(reflecting: node).children
        where viewTreeContains(child.value, target) {
            return true
        }
        return false
    }

    // MARK: - Shared helper truth table

    @Test @MainActor func bannerHelperRendersBannerWhenVisible() {
        #expect(viewTreeContains(
            featureRequestsSubmittedBanner(isVisible: true),
            SubmittedBanner.self
        ))
    }

    @Test @MainActor func bannerHelperRendersNothingWhenHidden() {
        #expect(!viewTreeContains(
            featureRequestsSubmittedBanner(isVisible: false),
            SubmittedBanner.self
        ))
    }

    // MARK: - Regression: empty post-submit reload keeps the confirmation

    @Test @MainActor func submittedBannerSurvivesEmptyPostSubmitReload() {
        // The exact regression shape: the submission succeeded, the banner was
        // set, and the immediately following reload returned an empty list.
        let view = FeatureRequestsView(
            client: makeTestClient(),
            userToken: "test_token",
            listState: FeatureRequestsListState(),
            loadState: makeResolvedLoadState(),
            showsSubmittedBanner: true
        )

        _ = view.body
        #expect(!view.isLoading)
        #expect(view.hasLoadedOnce)
        #expect(view.items.isEmpty)
        // The banner state machine is independent of the list state…
        #expect(view.isSubmittedBannerVisible)
        // …and the banner is actually composed into the presented output.
        #expect(viewTreeContains(view.body, SubmittedBanner.self))
    }

    @Test @MainActor func submittedBannerComposesAbovePopulatedList() {
        let view = FeatureRequestsView(
            client: makeTestClient(),
            userToken: "test_token",
            listState: FeatureRequestsListState(items: [makeItem(id: "req-1")]),
            loadState: makeResolvedLoadState(),
            showsSubmittedBanner: true
        )

        _ = view.body
        #expect(!view.items.isEmpty)
        #expect(view.isSubmittedBannerVisible)
        #expect(viewTreeContains(view.body, SubmittedBanner.self))
    }

    @Test @MainActor func submittedBannerIsAbsentByDefault() {
        let view = FeatureRequestsView(
            client: makeTestClient(),
            userToken: "test_token",
            listState: FeatureRequestsListState(items: [makeItem(id: "req-1")]),
            loadState: makeResolvedLoadState()
        )

        _ = view.body
        #expect(!view.isSubmittedBannerVisible)
        #expect(!viewTreeContains(view.body, SubmittedBanner.self))
    }
}
