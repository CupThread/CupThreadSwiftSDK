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

    // MARK: - Undecided access verdict (issue #369)

    @Test func affordanceStaysUndeterminedWhileVerdictIsInFlight() {
        let deniedConfig = makeConfig(allowAnonymousFeedback: false)
        // While the resolved-access verdict has not arrived, the sheet must
        // neither deny (placeholder flash for a signed-in user) nor open the
        // form (fail-closed preflight for a signed-out user).
        #expect(FeatureRequestComposeDismissalAffordance.resolve(
            config: deniedConfig,
            supportsAuthentication: true,
            verdictResolved: false
        ) == .undetermined)
        #expect(FeatureRequestComposeDismissalAffordance.resolve(
            config: deniedConfig,
            supportsAuthentication: false,
            verdictResolved: false
        ) == .undetermined)
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
        // A permitted config's verdict cannot depend on authentication, so the
        // form settles immediately — even before `.task` resolves access
        // (issue #369).
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

    @Test @MainActor func composeViewStaysUndeterminedWhileResolvingUnderDeniedConfig() {
        // Issue #369: with anonymous proposals denied and the access verdict
        // not yet resolved (the production presentation state on appearance),
        // the sheet starts in its neutral loading state — never the denial
        // placeholder a signed-in user would see flash before `.task`
        // resolves.
        let client = makeClient(authenticationProvider: { "signed-in-jwt" })
        let deniedConfig = makeConfig(allowAnonymousFeedback: false)
        let view = FeatureRequestComposeView(
            client: client,
            userToken: "test_token",
            config: deniedConfig
        ) {}
        #expect(view.dismissalAffordance == .undetermined)
        #expect(view.dismissalAffordance != .close)
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
        // the server stays authoritative (issue #233). View-level tests inject
        // the settled verdict instead of awaiting `.task` (issue #297).
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
        // satisfy the preflight: once the verdict settles on *no* access, the
        // denial placeholder with Close stays up instead of a form that can
        // only fail at submit (issue #297).
        let client = makeClient(authenticationProvider: { nil })
        let deniedConfig = makeConfig(allowAnonymousFeedback: false)
        let view = FeatureRequestComposeView(
            client: client,
            userToken: "test_token",
            config: deniedConfig,
            preResolvedAuthentication: false
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

    // MARK: - Post-submission draft reset (issue #424)

    @Test @MainActor func successfulSubmissionFiresCallbackAndSendsSeededDraft() async throws {
        // Each submission test gets its own mock host: Swift Testing runs
        // tests in parallel, and MockURLProtocol handlers are keyed by host.
        let host = "compose-success.test.example.com"
        let capture = CaptureBox<URLRequest>()
        let json: [String: Any] = ["featureRequestId": "fr_reset_1", "pending": true]
        MockURLProtocol.setHandler(forHost: host) { request in
            capture.value = request
            return (makeHTTPResponse(status: 201), try encodeJSON(json))
        }
        defer { MockURLProtocol.setHandler(forHost: host, nil) }

        var didSubmit = false
        let view = FeatureRequestComposeView(
            client: makeClient(baseURL: URL(string: "https://\(host)")!),
            userToken: "test_token",
            config: makeConfig(allowAnonymousFeedback: true),
            initialDraft: FeatureRequestDraft(
                title: "Dark mode support",
                description: "Please add dark mode.",
                requesterName: "Alice"
            )
        ) { didSubmit = true }

        await view.submit()

        #expect(didSubmit)
        let request = try #require(capture.value)
        let body = try #require(bodyData(from: request))
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["title"] as? String == "Dark mode support")
    }

    @Test @MainActor func failedSubmissionKeepsDraftForRetryAndSkipsCallback() async {
        let host = "compose-failure.test.example.com"
        MockURLProtocol.setHandler(forHost: host) { _ in
            (makeHTTPResponse(status: 500), try encodeJSON(["error": "boom"]))
        }
        defer { MockURLProtocol.setHandler(forHost: host, nil) }

        var didSubmit = false
        let view = FeatureRequestComposeView(
            client: makeClient(baseURL: URL(string: "https://\(host)")!),
            userToken: "test_token",
            config: makeConfig(allowAnonymousFeedback: true),
            initialDraft: FeatureRequestDraft(
                title: "Dark mode support",
                description: "Please add dark mode."
            )
        ) { didSubmit = true }

        await view.submit()

        #expect(!didSubmit, "a failed submission must not fire onSubmitted")
    }

    @Test func successfulSubmitPathResetsDraftBeforeCallback() throws {
        // SwiftUI @State is only writable inside a live view hierarchy, so the
        // draft reset itself cannot be observed on a unit-constructed view.
        // Follow the CancellationSuppressionTests source-scan pattern: the
        // success path must drop the draft between saving the proposal and
        // notifying the host, so `canSubmit` turns off and the accidental-
        // dismiss guard releases (issue #424).
        var directory = URL(fileURLWithPath: #filePath)
        var sourceURL: URL?
        for _ in 0..<6 {
            directory.deleteLastPathComponent()
            let candidate = directory
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("CupThreadFeedback", isDirectory: true)
                .appendingPathComponent("FeatureRequestComposeView.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                sourceURL = candidate
                break
            }
        }
        let content = try String(contentsOf: try #require(sourceURL), encoding: .utf8)

        let submitCall = try #require(
            content.range(of: "_ = try await client.submitFeatureRequest"),
            "submit success path not found"
        )
        let callback = try #require(
            content.range(of: "onSubmitted()", range: submitCall.upperBound..<content.endIndex),
            "onSubmitted() after the submit call not found"
        )
        let between = content[submitCall.upperBound..<callback.lowerBound]
        #expect(
            between.contains("draft = FeatureRequestDraft()"),
            "a successful submission must reset the draft before onSubmitted() so the dismiss guard releases (issue #424)"
        )
    }

    @Test func resetDraftReleasesSubmitGuardAndDismissConfirmation() {
        // What the reset buys the user: once the draft empties, the submit
        // guard drops (no duplicate proposals) and a leave attempt no longer
        // asks for discard confirmation — the content is already saved
        // server-side.
        var draft = FeatureRequestDraft(
            title: "Dark mode support",
            description: "Please add dark mode."
        )
        #expect(draft.hasContent)
        #expect(
            ComposerDismissalDecision.resolve(hasContent: draft.hasContent, isSubmitting: false)
                == .confirmDiscard
        )

        draft = FeatureRequestDraft()
        #expect(!draft.hasContent)
        #expect(
            ComposerDismissalDecision.resolve(hasContent: draft.hasContent, isSubmitting: false)
                == .dismiss
        )
    }
}
