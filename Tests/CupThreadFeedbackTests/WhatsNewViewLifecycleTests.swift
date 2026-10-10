import Foundation
import SwiftUI
import Testing
@testable import CupThreadFeedback

// MARK: - Load task key (issues #265, #364)

@Suite("WhatsNewLoadTaskKey")
struct WhatsNewLoadTaskKeyTests {
    @Test func anonymousChangelogSwitchFlipChangesTheKey() {
        #expect(
            makeChangelogLoadTaskKey(allowsAnonymousChangelog: false)
                != makeChangelogLoadTaskKey(allowsAnonymousChangelog: true)
        )
    }

    @Test func unchangedSwitchProducesTheSameKey() {
        #expect(
            makeChangelogLoadTaskKey(allowsAnonymousChangelog: true)
                == makeChangelogLoadTaskKey(allowsAnonymousChangelog: true)
        )
        #expect(
            makeChangelogLoadTaskKey(allowsAnonymousChangelog: false)
                == makeChangelogLoadTaskKey(allowsAnonymousChangelog: false)
        )
    }
}

// MARK: - Lifecycle & Task Key Stability Tests (Issue #364)

@Suite("WhatsNewView Lifecycle Tests")
struct WhatsNewViewLifecycleTests {
    private func makeTestClient() -> FeedbackClient {
        makeClient(appKey: "app_test_dummy_key_123456")
    }

    private func makeWhatsNewConfig(allowAnonymousChangelog: Bool) -> PublicAppConfig {
        PublicAppConfig(
            appId: "app-1",
            appKey: "app_testkey123456",
            slug: "demo",
            name: "Demo",
            allowPublic: true,
            allowedPlatforms: nil,
            allowedPlatformValues: [],
            allowAnonymousRoadmap: true,
            allowAnonymousVote: true,
            allowAnonymousFeedback: true,
            allowAnonymousChangelog: allowAnonymousChangelog
        )
    }

    @Test @MainActor func loadTaskKeyIsStableAcrossAuthenticationResolutionUnderLockedDownConfig() {
        // Issue #364: the task's first act resolves authentication. Keyed on
        // the resolved verdict, that flip changed the key mid-flight, so
        // SwiftUI cancelled the in-flight task and restarted the load from
        // scratch. The key must be identical before the verdict settles, for
        // a resolved signed-in user, and for a resolved signed-out user —
        // locked-down switch.
        let lockedDown = makeWhatsNewConfig(allowAnonymousChangelog: false)
        let unresolved = WhatsNewView(
            client: makeTestClient(),
            userToken: "user_test_token_123",
            configOverride: lockedDown
        )
        let signedIn = WhatsNewView(
            client: makeTestClient(),
            userToken: "user_test_token_123",
            configOverride: lockedDown,
            preResolvedAuthentication: true
        )
        let signedOut = WhatsNewView(
            client: makeTestClient(),
            userToken: "user_test_token_123",
            configOverride: lockedDown,
            preResolvedAuthentication: false
        )

        #expect(unresolved.loadTaskKey == signedIn.loadTaskKey)
        #expect(unresolved.loadTaskKey == signedOut.loadTaskKey)
        #expect(signedIn.loadTaskKey == signedOut.loadTaskKey)
    }

    @Test @MainActor func loadTaskKeyStillTracksTheAnonymousChangelogSwitch() {
        // The #265 contract survives on the config switch: a flip of the
        // anonymous-changelog switch must restart the task, while a switch-stable
        // config refresh must keep the key — and the in-flight load — unchanged.
        let deniedView = WhatsNewView(
            client: makeTestClient(),
            userToken: "user_test_token_123",
            configOverride: makeWhatsNewConfig(allowAnonymousChangelog: false),
            preResolvedAuthentication: false
        )
        let allowedView = WhatsNewView(
            client: makeTestClient(),
            userToken: "user_test_token_123",
            configOverride: makeWhatsNewConfig(allowAnonymousChangelog: true),
            preResolvedAuthentication: false
        )
        let refreshedAllowedView = WhatsNewView(
            client: makeTestClient(),
            userToken: "user_test_token_123",
            configOverride: makeWhatsNewConfig(allowAnonymousChangelog: true),
            preResolvedAuthentication: false
        )

        #expect(deniedView.loadTaskKey != allowedView.loadTaskKey)
        #expect(allowedView.loadTaskKey == refreshedAllowedView.loadTaskKey)
    }

    @Test func authenticationResolutionDoesNotMutateTaskKeyDuringExecution() {
        let config = makeWhatsNewConfig(allowAnonymousChangelog: false)

        // When authenticated access is not yet resolved:
        var isAuthenticated = false
        let initialPermitted = changelogLoadPlan(config: config, supportsAuthentication: isAuthenticated) == .load
        #expect(initialPermitted == false)

        // When authenticated access resolves:
        isAuthenticated = true
        let resolvedPermitted = changelogLoadPlan(config: config, supportsAuthentication: isAuthenticated) == .load
        #expect(resolvedPermitted == true)

        // Task identity must not transition from false to true via internal state mutation;
        // it should be keyed on external configuration:
        let stableKey = makeChangelogLoadTaskKey(allowsAnonymousChangelog: config.allowsAnonymousChangelog)
        #expect(stableKey == false)
    }
}
