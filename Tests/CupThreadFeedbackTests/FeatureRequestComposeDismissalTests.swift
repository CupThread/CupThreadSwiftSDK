import Foundation
import SwiftUI
import Testing
@testable import CupThreadFeedback

@Suite("FeatureRequestCompose dismissal controls")
struct FeatureRequestComposeDismissalTests {
    private func makeConfig(allowAnonymousFeedback: Bool) -> PublicAppConfig {
        PublicAppConfig(
            appId: "app-1",
            appKey: "app_testkey123456",
            slug: "demo",
            name: "Demo",
            allowPublic: true,
            allowAnonymousFeedback: allowAnonymousFeedback
        )
    }

    // MARK: - Dismissal affordance decision table

    @Test func affordanceResolvesToGuardedCancelWhenAnonymousProposalsAllowed() {
        let config = makeConfig(allowAnonymousFeedback: true)
        #expect(FeatureRequestComposeDismissalAffordance.resolve(config: config) == .guardedCancel)
    }

    @Test func affordanceFailsOpenWhenConfigIsNil() {
        #expect(FeatureRequestComposeDismissalAffordance.resolve(config: nil) == .guardedCancel)
    }

    @Test func affordanceResolvesToCloseWhenAnonymousProposalsDenied() {
        let config = makeConfig(allowAnonymousFeedback: false)
        #expect(FeatureRequestComposeDismissalAffordance.resolve(config: config) == .close)
    }

    // MARK: - Localized string checks

    @Test func composeTitleResolvesThroughModuleBundle() {
        let title = CupThreadStrings.tr("cupthread.features.compose_title")
        #expect(title != "cupthread.features.compose_title")
        #expect(!title.isEmpty)
    }

    @Test func closeButtonTitleResolvesThroughModuleBundle() {
        let close = CupThreadStrings.tr("cupthread.whatsnew.close_button")
        #expect(close != "cupthread.whatsnew.close_button")
        #expect(!close.isEmpty)
    }

    // MARK: - View body evaluation

    @Test @MainActor func composeViewEvaluatesBodyUnderPermittedConfig() {
        let client = makeClient()
        let permittedConfig = makeConfig(allowAnonymousFeedback: true)
        let view = FeatureRequestComposeView(
            client: client,
            userToken: "test_token",
            config: permittedConfig
        ) {}
        #expect(view.dismissalAffordance == .guardedCancel)
        _ = view.body
    }

    @Test @MainActor func composeViewEvaluatesBodyUnderDeniedConfig() {
        let client = makeClient()
        let deniedConfig = makeConfig(allowAnonymousFeedback: false)
        let view = FeatureRequestComposeView(
            client: client,
            userToken: "test_token",
            config: deniedConfig
        ) {}
        #expect(view.dismissalAffordance == .close)
        _ = view.body
    }

    @Test @MainActor func composeViewFailsOpenWhenConfigIsNil() {
        let client = makeClient()
        let view = FeatureRequestComposeView(client: client, userToken: "test_token") {}
        #expect(view.dismissalAffordance == .guardedCancel)
        _ = view.body
    }

    @Test @MainActor func composeViewShowsFormForAuthenticatedClientUnderDeniedConfig() {
        // A resolved bearer token satisfies the anonymous-proposal preflight;
        // the server stays authoritative (issue #233). The verdict arrives
        // asynchronously in `.task` (issue #297), so view-level tests inject
        // the resolved value.
        let client = makeClient(authenticationProvider: { "signed-in-jwt" })
        let deniedConfig = makeConfig(allowAnonymousFeedback: false)
        let view = FeatureRequestComposeView(
            client: client,
            userToken: "test_token",
            config: deniedConfig,
            preResolvedAuthentication: true
        ) {}
        #expect(view.dismissalAffordance == .guardedCancel)
        _ = view.body
    }

    @Test @MainActor func composeViewStaysDeniedForSignedOutClientUnderDeniedConfig() {
        // An installed provider that answers `nil` (signed out) does not
        // satisfy the preflight: the denial placeholder with Close stays up
        // instead of a form that can only fail at submit (issue #297).
        let client = makeClient(authenticationProvider: { nil })
        let deniedConfig = makeConfig(allowAnonymousFeedback: false)
        let view = FeatureRequestComposeView(
            client: client,
            userToken: "test_token",
            config: deniedConfig
        ) {}
        #expect(view.dismissalAffordance == .close)
        _ = view.body
    }

    @Test @MainActor func denialSheetEvaluatesBodyAndFiresDismissCallback() {
        var didDismiss = false
        let sheet = FeatureRequestDenialSheet {
            didDismiss = true
        }
        _ = sheet.body
        sheet.onDismiss()
        #expect(didDismiss)
    }
}
