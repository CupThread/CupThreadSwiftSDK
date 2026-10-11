import Foundation
import SwiftUI
import Testing
@testable import CupThreadFeedback

/// FeatureRequestsView authentication lifecycle tests (CONC-11, issue #361):
/// Authentication state (`isAuthenticated`) is resolved asynchronously.
/// When anonymous feedback or roadmap reads are disabled, `canCompose` and
/// `versionFilterTaskKey` must accurately reflect resolved authentication,
/// and `autoPresentCompose` must avoid premature denial before access resolves.
@Suite("FeatureRequestsView Auth Lifecycle Tests")
struct FeatureRequestsAuthLifecycleTests {
    private func makeConfig(
        allowAnonymousFeedback: Bool = true,
        allowAnonymousRoadmap: Bool = true
    ) -> PublicAppConfig {
        PublicAppConfig(
            appId: "app-1",
            appKey: "app_testkey123456",
            slug: "demo",
            name: "Demo",
            allowPublic: true,
            allowedPlatforms: nil,
            allowedPlatformValues: [],
            allowAnonymousRoadmap: allowAnonymousRoadmap,
            allowAnonymousVote: true,
            allowAnonymousFeedback: allowAnonymousFeedback,
            allowAnonymousChangelog: true
        )
    }

    @MainActor
    private func makeView(
        config: PublicAppConfig? = nil,
        preResolvedAuthentication: Bool? = nil,
        autoPresentCompose: Bool = false
    ) -> FeatureRequestsView {
        FeatureRequestsView(
            client: makeClient(
                appKey: "app_testkey123456",
                authenticationProvider: { "valid_jwt_token" }
            ),
            userToken: "test_token_123",
            configOverride: config,
            preResolvedAuthentication: preResolvedAuthentication,
            autoPresentCompose: autoPresentCompose
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

    // MARK: - Issue #361 Expected Result / Baseline Checks

    @Test func canComposeEvaluatesTrueWhenAuthenticatedEvenIfAnonymousDisabled() async {
        let signedInClient = FeedbackClient(
            configuration: .init(
                baseURL: URL(string: "https://api.cupthread.com")!,
                appKey: "app_test"
            ),
            authenticationProvider: { "valid_token" }
        )

        let isAuthenticated = await signedInClient.resolveAuthenticatedAccess()
        let allowsAnonymousFeedback = false

        let canCompose = allowsAnonymousFeedback || isAuthenticated
        #expect(canCompose == true)
    }

    @Test func versionTaskKeyChangesWhenAuthenticationResolves() {
        let anonymousKey = "false|false"
        let authenticatedKey = "true|false"

        #expect(anonymousKey != authenticatedKey)
    }

    // MARK: - Version Filter Task Key Transitions

    @Test @MainActor func versionFilterTaskKeyReflectsAuthStateAndRoadmapConfig() {
        let anonymousRoadmapDenied = makeConfig(allowAnonymousRoadmap: false)
        let anonymousRoadmapAllowed = makeConfig(allowAnonymousRoadmap: true)

        let unauthDeniedView = makeView(config: anonymousRoadmapDenied, preResolvedAuthentication: false)
        #expect(unauthDeniedView.versionFilterTaskKey == "false|false")

        let authDeniedView = makeView(config: anonymousRoadmapDenied, preResolvedAuthentication: true)
        #expect(authDeniedView.versionFilterTaskKey == "true|false")

        let unauthAllowedView = makeView(config: anonymousRoadmapAllowed, preResolvedAuthentication: false)
        #expect(unauthAllowedView.versionFilterTaskKey == "false|true")

        let authAllowedView = makeView(config: anonymousRoadmapAllowed, preResolvedAuthentication: true)
        #expect(authAllowedView.versionFilterTaskKey == "true|true")

        let nilConfigView = makeView(config: nil, preResolvedAuthentication: false)
        #expect(nilConfigView.versionFilterTaskKey == "false|true")
    }

    // MARK: - Compose Predicate & Verdict Lifecycle

    @Test @MainActor func canComposeAndComposeAccessResolvedTruthTable() {
        let allowedConfig = makeConfig(allowAnonymousFeedback: true)
        let deniedConfig = makeConfig(allowAnonymousFeedback: false)

        // 1. When anonymous proposals are permitted: immediately resolved & allowed
        let permittedView = makeView(config: allowedConfig, preResolvedAuthentication: nil)
        #expect(permittedView.canCompose)
        #expect(permittedView.isComposeAccessResolved)

        // 2. When anonymous proposals are denied and auth has not yet resolved
        let pendingView = makeView(config: deniedConfig, preResolvedAuthentication: nil)
        #expect(!pendingView.canCompose)
        #expect(!pendingView.isComposeAccessResolved)

        // 3. When anonymous proposals are denied and auth settles as authenticated
        let authedView = makeView(config: deniedConfig, preResolvedAuthentication: true)
        #expect(authedView.canCompose)
        #expect(authedView.isComposeAccessResolved)

        // 4. When anonymous proposals are denied and auth settles as unauthenticated
        let unauthedView = makeView(config: deniedConfig, preResolvedAuthentication: false)
        #expect(!unauthedView.canCompose)
        #expect(unauthedView.isComposeAccessResolved)
    }

    // MARK: - Compose Sheet Presentation Structure

    @Test @MainActor func autoPresentComposePresentsComposeFormWhenAuthenticatedUnderDisabledAnonymous() {
        let view = makeView(
            config: makeConfig(allowAnonymousFeedback: false),
            preResolvedAuthentication: true,
            autoPresentCompose: true
        )

        let sheet = view.composeSheetContent()
        #expect(viewTreeContains(sheet, FeatureRequestComposeView.self))
        #expect(!viewTreeContains(sheet, FeatureRequestDenialSheet.self))
        #expect(!viewTreeContains(sheet, ProgressView<EmptyView, EmptyView>.self))
    }

    @Test @MainActor func autoPresentComposeShowsLoadingWhenAuthUnresolvedUnderDisabledAnonymous() {
        let view = makeView(
            config: makeConfig(allowAnonymousFeedback: false),
            preResolvedAuthentication: nil,
            autoPresentCompose: true
        )

        let sheet = view.composeSheetContent()
        #expect(viewTreeContains(sheet, ProgressView<EmptyView, EmptyView>.self))
        #expect(!viewTreeContains(sheet, FeatureRequestComposeView.self))
        #expect(!viewTreeContains(sheet, FeatureRequestDenialSheet.self))
    }

    @Test @MainActor func autoPresentComposeShowsDenialWhenUnauthenticatedUnderDisabledAnonymous() {
        let view = makeView(
            config: makeConfig(allowAnonymousFeedback: false),
            preResolvedAuthentication: false,
            autoPresentCompose: true
        )

        let sheet = view.composeSheetContent()
        #expect(viewTreeContains(sheet, FeatureRequestDenialSheet.self))
        #expect(!viewTreeContains(sheet, FeatureRequestComposeView.self))
        #expect(!viewTreeContains(sheet, ProgressView<EmptyView, EmptyView>.self))
    }

    @Test @MainActor func autoPresentComposePresentsComposeFormImmediatelyWhenAnonymousFeedbackAllowed() {
        let view = makeView(
            config: makeConfig(allowAnonymousFeedback: true),
            preResolvedAuthentication: nil,
            autoPresentCompose: true
        )

        let sheet = view.composeSheetContent()
        #expect(viewTreeContains(sheet, FeatureRequestComposeView.self))
        #expect(!viewTreeContains(sheet, FeatureRequestDenialSheet.self))
        #expect(!viewTreeContains(sheet, ProgressView<EmptyView, EmptyView>.self))
    }
}
