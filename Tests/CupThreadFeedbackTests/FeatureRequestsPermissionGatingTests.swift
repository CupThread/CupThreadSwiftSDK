import Foundation
import SwiftUI
import Testing
@testable import CupThreadFeedback

/// FeatureRequestsView permission gating tests (SEC-16, issue #363):
/// When an organization disables anonymous roadmap reads (`allowsAnonymousRoadmap == false`
/// or `allowPublic == false`), `FeatureRequestsView` must enforce access control
/// preflights and render `SdkPermissionDeniedView` instead of leaking network requests
/// or surfacing raw 401/403 errors.
@Suite("FeatureRequestsView Roadmap Permission Gating Tests")
struct FeatureRequestsPermissionGatingTests {
    private func makeConfig(
        allowPublic: Bool = true,
        allowAnonymousRoadmap: Bool = true
    ) -> PublicAppConfig {
        PublicAppConfig(
            appId: "app-1",
            appKey: "app_testkey123456",
            slug: "demo",
            name: "Demo",
            allowPublic: allowPublic,
            allowedPlatforms: nil,
            allowedPlatformValues: [],
            allowAnonymousRoadmap: allowAnonymousRoadmap,
            allowAnonymousVote: true,
            allowAnonymousFeedback: true,
            allowAnonymousChangelog: true
        )
    }

    private func makeView(
        config: PublicAppConfig?,
        preResolvedAuthentication: Bool? = nil,
        rejectedByServer: Bool = false
    ) -> FeatureRequestsView {
        FeatureRequestsView(
            client: makeClient(appKey: "app_testkey123456"),
            userToken: "test_token_123",
            configOverride: config,
            preResolvedAuthentication: preResolvedAuthentication,
            rejectedByServer: rejectedByServer
        )
    }

    private func viewTreeContains(_ node: Any, _ target: Any.Type) -> Bool {
        if type(of: node) == target { return true }
        for child in Mirror(reflecting: node).children
        where viewTreeContains(child.value, target) {
            return true
        }
        return false
    }

    // MARK: - Predicate truth tables

    @Test func roadmapPermissionBlockedWhenAnonymousDisabledAndUnauthenticated() {
        let config = makeConfig(allowAnonymousRoadmap: false)
        let permitted = roadmapLoadPlan(config: config, supportsAuthentication: false) == .load
        #expect(!permitted)

        let isBlocked = isSurfacePermissionBlocked(
            verdictResolved: true,
            permitted: permitted,
            rejectedByServer: false
        )
        #expect(isBlocked)
    }

    @Test func roadmapPermittedWhenAuthenticatedEvenIfAnonymousDisabled() {
        let config = makeConfig(allowAnonymousRoadmap: false)
        let permitted = roadmapLoadPlan(config: config, supportsAuthentication: true) == .load
        #expect(permitted)

        let isBlocked = isSurfacePermissionBlocked(
            verdictResolved: true,
            permitted: permitted,
            rejectedByServer: false
        )
        #expect(!isBlocked)
    }

    @Test func server401RejectionTriggersBlockedState() {
        let isBlocked = isSurfacePermissionBlocked(
            verdictResolved: true,
            permitted: true,
            rejectedByServer: true
        )
        #expect(isBlocked)
    }

    @Test func unsettledVerdictDoesNotPrematurelyBlock() {
        let isBlocked = isSurfacePermissionBlocked(
            verdictResolved: false,
            permitted: false,
            rejectedByServer: false
        )
        #expect(!isBlocked)
    }

    // MARK: - View-level computed property checks

    @Test @MainActor func featureRequestsViewGatesAccessOnAnonymousRoadmapSwitch() {
        let deniedView = makeView(
            config: makeConfig(allowAnonymousRoadmap: false),
            preResolvedAuthentication: false
        )
        #expect(!deniedView.isRoadmapPermitted)
        #expect(deniedView.isRoadmapVerdictResolved)
        #expect(deniedView.isRoadmapPermissionBlocked)

        let permittedView = makeView(
            config: makeConfig(allowAnonymousRoadmap: true),
            preResolvedAuthentication: false
        )
        #expect(permittedView.isRoadmapPermitted)
        #expect(permittedView.isRoadmapVerdictResolved)
        #expect(!permittedView.isRoadmapPermissionBlocked)
    }

    @Test @MainActor func featureRequestsViewAdmitsAuthenticatedUserUnderDisabledAnonymousSwitch() {
        let authenticatedView = makeView(
            config: makeConfig(allowAnonymousRoadmap: false),
            preResolvedAuthentication: true
        )
        #expect(authenticatedView.isRoadmapPermitted)
        #expect(authenticatedView.isRoadmapVerdictResolved)
        #expect(!authenticatedView.isRoadmapPermissionBlocked)
    }

    @Test @MainActor func featureRequestsViewBlocksOnServerRejectionEvenWhenPermitted() {
        let rejectedView = makeView(
            config: makeConfig(allowAnonymousRoadmap: true),
            preResolvedAuthentication: false,
            rejectedByServer: true
        )
        #expect(rejectedView.isRoadmapPermitted)
        #expect(rejectedView.isRoadmapVerdictResolved)
        #expect(rejectedView.isRoadmapPermissionBlocked)
    }

    @Test @MainActor func featureRequestsViewUnsettledVerdictDoesNotPrematurelyBlock() {
        let unsettledLockedDownView = makeView(
            config: makeConfig(allowAnonymousRoadmap: false),
            preResolvedAuthentication: nil
        )
        #expect(!unsettledLockedDownView.isRoadmapVerdictResolved)
        #expect(!unsettledLockedDownView.isRoadmapPermissionBlocked)
    }

    // MARK: - View tree structural assertions

    @Test @MainActor func featureRequestsViewRendersPermissionDeniedPlaceholderWhenBlocked() {
        let view = makeView(
            config: makeConfig(allowAnonymousRoadmap: false),
            preResolvedAuthentication: false
        )
        #expect(view.isRoadmapPermissionBlocked)
        #expect(viewTreeContains(view.body, SdkPermissionDeniedView.self))
    }

    @Test @MainActor func featureRequestsViewDoesNotRenderPermissionDeniedPlaceholderWhenPermitted() {
        let view = makeView(
            config: makeConfig(allowAnonymousRoadmap: true),
            preResolvedAuthentication: false
        )
        #expect(!view.isRoadmapPermissionBlocked)
        #expect(!viewTreeContains(view.body, SdkPermissionDeniedView.self))
    }

    @Test @MainActor func featureRequestsViewRendersPermissionDeniedOnServerRejection() {
        let view = makeView(
            config: makeConfig(allowAnonymousRoadmap: true),
            preResolvedAuthentication: true,
            rejectedByServer: true
        )
        #expect(view.isRoadmapPermissionBlocked)
        #expect(viewTreeContains(view.body, SdkPermissionDeniedView.self))
    }
}
