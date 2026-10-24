import Foundation
import SwiftUI
import Testing
@testable import CupThreadFeedback

// MARK: - UserProfileView reload preservation (issue #545)

/// Pull-to-refresh on a rendered profile must never collapse it to a bare
/// spinner, and a failed refresh must never replace it with the full-screen
/// error — the #59/#534 preserve-content invariant extended to the
/// `SurfaceLoadState` surfaces (the CommentsView sibling of this suite pins
/// the shared state model and the submit/refresh interleave).
@Suite("UserProfileView Reload Preservation")
struct UserProfileViewReloadPreservationTests {
    // MARK: - Body branch order (source-scan)

    /// The loading branch owns the surface only before the first successful
    /// load; a reload in flight over a rendered profile must not fall into it.
    @Test func loadingBranchRequiresNoSuccessfulLoadYet() throws {
        let content = try String(
            contentsOf: try #require(Self.userProfileViewSourceURL()),
            encoding: .utf8
        )

        let loadingBranch = try #require(
            content.range(of: "loadState.isLoading && !loadState.hasLoadedOnce"),
            "the loading branch must require `!hasLoadedOnce` so a reload never collapses a rendered profile to a spinner (issue #545)"
        )
        let fullScreenError = try #require(
            content.range(of: "LoadErrorView(message: loadError)", range: loadingBranch.upperBound..<content.endIndex)
        )
        let branchCondition = content[loadingBranch.upperBound..<fullScreenError.lowerBound]
        #expect(
            branchCondition.contains("profile == nil"),
            "LoadErrorView must own the surface only when there is nothing to show (issue #545)"
        )
    }

    /// The failed-refresh notice renders as the inline banner overlay, the
    /// local precedent from WhatsNewView (#534).
    @Test func failureNoticeOverlaysTheRenderedProfile() throws {
        let content = try String(
            contentsOf: try #require(Self.userProfileViewSourceURL()),
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

    /// The load path must pin `hasLoadedOnce` on success and preserve a
    /// rendered profile on failure (`@State` writes are not observable on a
    /// unit-constructed view, so the wiring is pinned with the established
    /// source-scan pattern).
    @Test func loadPathRecordsSuccessAndPreservesRenderedContentOnFailure() throws {
        let content = try String(
            contentsOf: try #require(Self.userProfileViewSourceURL()),
            encoding: .utf8
        )

        let fetch = try #require(
            content.range(of: "client.fetchUserProfile(userId: userId)"),
            "the fetch anchor was renamed; update this scan"
        )
        let successPath = content[fetch.upperBound..<content.endIndex]
        #expect(
            successPath.contains("loadState.recordSuccess(generation: generation)"),
            "a successful load must pin hasLoadedOnce so the loading branch cannot reclaim the surface (issue #545)"
        )
        #expect(
            successPath.contains("hasExistingContent: profile != nil"),
            "a load failure must preserve an already-rendered profile via the inline notice (issue #545)"
        )
    }

    // MARK: - Rendering with seeded state

    private static func makeProfile() -> PublicUserProfileResponse {
        PublicUserProfileResponse(
            profile: UserProfile(
                clerkUserId: "u_1a2b3c4d5e6f708192a3b4c5d6e7f809",
                displayName: "Ada",
                avatarUrl: nil,
                bio: "Bio",
                websiteUrl: nil,
                createdAt: "2026-01-01T00:00:00.000Z"
            ),
            publicApps: [],
            recentComments: []
        )
    }

    @Test @MainActor func renderedProfileSurvivesARefreshInProgressWithoutASpinner() {
        let view = UserProfileView(
            client: makeClient(),
            userId: "u_1a2b3c4d5e6f708192a3b4c5d6e7f809",
            initialProfile: Self.makeProfile(),
            initialLoadState: SurfaceLoadState(isLoading: true, hasLoadedOnce: true)
        )

        _ = view.body
        #expect(view.isLoading)
        #expect(view.hasLoadedOnce)
        // The reload never reclaims the surface: no spinner frame exists in
        // the rendered tree while the profile is on screen (issue #545).
        #expect(!viewTreeContains(view.body, ProgressView<EmptyView, EmptyView>.self))
    }

    @Test @MainActor func renderedProfileWithAFailedRefreshKeepsTheProfileAndShowsTheNotice() {
        let view = UserProfileView(
            client: makeClient(),
            userId: "u_1a2b3c4d5e6f708192a3b4c5d6e7f809",
            initialProfile: Self.makeProfile(),
            initialLoadState: SurfaceLoadState(
                isLoading: false,
                hasLoadedOnce: true,
                loadError: nil,
                reloadNotice: "Network connection lost"
            )
        )

        _ = view.body
        #expect(view.loadError == nil, "a failure with content on screen must not write the full-screen verdict")
        #expect(view.reloadNotice == "Network connection lost")
        #expect(!viewTreeContains(view.body, LoadErrorView.self))
    }

    @Test @MainActor func firstLoadFailureStillUsesFullScreenError() {
        // No regression of the empty case: a first-load failure has nothing
        // to preserve and fills the surface with the full-screen error.
        let view = UserProfileView(
            client: makeClient(),
            userId: "u_1a2b3c4d5e6f708192a3b4c5d6e7f809",
            initialProfile: nil,
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
        let view = UserProfileView(
            client: makeClient(),
            userId: "u_1a2b3c4d5e6f708192a3b4c5d6e7f809",
            initialProfile: nil
        )

        _ = view.body
        #expect(view.isLoading)
        #expect(!view.hasLoadedOnce)
        #expect(viewTreeContains(view.body, ProgressView<EmptyView, EmptyView>.self))
    }

    // MARK: - Failed-refresh lifecycle

    /// A failed refresh must not short-circuit the surface: the retry still
    /// issues a request and recovers, mirroring the WhatsNewView lifecycle
    /// pin from #534.
    @Test @MainActor func failedRefreshKeepsTheProfileRetryableAndRecoverable() async throws {
        let apiHost = "profile-refresh-545.test.example.com"
        let requestCounter = CaptureBox<Int>()
        requestCounter.value = 0

        let payload: [String: Any] = [
            "profile": [
                "clerkUserId": "u_1a2b3c4d5e6f708192a3b4c5d6e7f809",
                "displayName": "Ada",
                "avatarUrl": NSNull(),
                "bio": NSNull(),
                "websiteUrl": NSNull(),
                "createdAt": "2026-01-01T00:00:00.000Z"
            ],
            "publicApps": [],
            "recentComments": []
        ]

        MockURLProtocol.setHandler(forHost: apiHost) { request in
            let count = (requestCounter.value ?? 0) + 1
            requestCounter.value = count
            if count == 2 {
                throw URLError(.notConnectedToInternet)
            }
            #expect(request.url?.path == "/api/v1/users/u_1a2b3c4d5e6f708192a3b4c5d6e7f809/profile")
            return (makeHTTPResponse(), try encodeJSON(payload))
        }
        defer { MockURLProtocol.setHandler(forHost: apiHost, nil) }

        let view = UserProfileView(
            client: makeClient(baseURL: URL(string: "https://\(apiHost)")!),
            userId: "u_1a2b3c4d5e6f708192a3b4c5d6e7f809"
        )

        await view.loadProfile() // initial load succeeds
        await view.loadProfile() // refresh fails
        await view.loadProfile() // retry recovers

        let requests = try #require(requestCounter.value)
        #expect(requests == 3, "the failed refresh must not lock the surface out of further loads")
    }

    // MARK: - Fixtures

    private static func userProfileViewSourceURL() -> URL? {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            directory.deleteLastPathComponent()
            let candidate = directory
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("CupThreadFeedback", isDirectory: true)
                .appendingPathComponent("UserProfileView.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
