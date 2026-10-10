import Foundation
import SwiftUI
import Testing
@testable import CupThreadFeedback

@Suite("FeedbackComposer dismissal controls")
struct FeedbackComposerDismissalTests {
    private func makeConfig(
        allowedPlatforms: [FeedbackPlatform]? = nil,
        allowedPlatformValues: [String] = [],
        allowAnonymousFeedback: Bool = true
    ) -> PublicAppConfig {
        PublicAppConfig(
            appId: "app-1",
            appKey: "app_testkey123456",
            slug: "demo",
            name: "Demo",
            allowPublic: true,
            allowedPlatforms: allowedPlatforms,
            allowedPlatformValues: allowedPlatformValues,
            allowAnonymousFeedback: allowAnonymousFeedback
        )
    }

    private func makeSubmissionResult(warning: String? = nil) -> FeedbackSubmissionResult {
        FeedbackSubmissionResult(
            submissionId: "sub_12345",
            warning: warning
        )
    }

    // MARK: - Dismissal affordance decision table

    @Test func affordanceResolvesToDoneWhenResultIsPresent() {
        let result = makeSubmissionResult()
        let denial = SdkSubmissionDenial.none
        #expect(FeedbackComposerDismissalAffordance.resolve(result: result, denial: denial) == .done)

        let deniedAffordance = FeedbackComposerDismissalAffordance.resolve(
            result: result,
            denial: .anonymousFeedbackDisabled
        )
        #expect(deniedAffordance == .done)
    }

    @Test func affordanceResolvesToCancelWhenAnonymousFeedbackDisabled() {
        let denial = SdkSubmissionDenial.anonymousFeedbackDisabled
        #expect(FeedbackComposerDismissalAffordance.resolve(result: nil, denial: denial) == .cancel)
    }

    @Test func affordanceResolvesToCancelWhenPlatformNotAllowed() {
        let denial = SdkSubmissionDenial.platformNotAllowed
        #expect(FeedbackComposerDismissalAffordance.resolve(result: nil, denial: denial) == .cancel)
    }

    @Test func affordanceResolvesToGuardedCancelWhenPermittedAndNoResult() {
        let denial = SdkSubmissionDenial.none
        #expect(FeedbackComposerDismissalAffordance.resolve(result: nil, denial: denial) == .guardedCancel)
    }

    // MARK: - Undecided access verdict (issue #367)

    @Test func affordanceStaysUndeterminedWhileVerdictIsInFlight() {
        let deniedConfig = makeConfig(allowAnonymousFeedback: false)
        // While the resolved-access verdict has not arrived, the composer must
        // neither deny (placeholder flash for a signed-in user) nor open the
        // form (fail-closed preflight for a signed-out user).
        #expect(FeedbackComposerDismissalAffordance.resolve(
            result: nil,
            denial: SdkSubmissionDenial.forFeedback(
                config: deniedConfig,
                platform: .ios,
                supportsAuthentication: true
            ),
            verdictResolved: false
        ) == .undetermined)
        #expect(FeedbackComposerDismissalAffordance.resolve(
            result: nil,
            denial: SdkSubmissionDenial.forFeedback(
                config: deniedConfig,
                platform: .ios,
                supportsAuthentication: false
            ),
            verdictResolved: false
        ) == .undetermined)
    }

    // MARK: - Localized string checks

    @Test func commonDoneStringResolvesThroughModuleBundle() {
        let done = CupThreadStrings.tr("cupthread.common.done")
        #expect(done != "cupthread.common.done")
        #expect(!done.isEmpty)
    }

    @Test func commonCancelStringResolvesThroughModuleBundle() {
        let cancel = CupThreadStrings.tr("cupthread.common.cancel")
        #expect(cancel != "cupthread.common.cancel")
        #expect(!cancel.isEmpty)
    }

    @Test func feedbackSentStringsResolveThroughModuleBundle() {
        let thanksTitle = CupThreadStrings.tr("cupthread.feedback.thanks_title")
        let thanksSubtitle = CupThreadStrings.tr("cupthread.feedback.thanks_subtitle")
        let sendMore = CupThreadStrings.tr("cupthread.feedback.send_more")
        let accessibilitySent = CupThreadStrings.tr("cupthread.feedback.accessibility_sent")

        #expect(thanksTitle != "cupthread.feedback.thanks_title")
        #expect(thanksSubtitle != "cupthread.feedback.thanks_subtitle")
        #expect(sendMore != "cupthread.feedback.send_more")
        #expect(accessibilitySent != "cupthread.feedback.accessibility_sent")
    }

    // MARK: - FeedbackSentView evaluation & callbacks

    @Test @MainActor func sentViewEvaluatesBodyWithoutWarning() {
        var didDismiss = false
        var didSendMore = false
        let view = FeedbackSentView(
            warning: nil,
            onDismiss: { didDismiss = true },
            onSendMore: { didSendMore = true }
        )
        _ = view.body
        #expect(!didDismiss)
        #expect(!didSendMore)
    }

    @Test @MainActor func sentViewEvaluatesBodyWithWarning() {
        let view = FeedbackSentView(
            warning: "Upload took longer than usual",
            onDismiss: {},
            onSendMore: {}
        )
        _ = view.body
    }

    @Test @MainActor func sentViewTriggersDismissAndSendMoreCallbacks() {
        var didDismiss = false
        var didSendMore = false
        let view = FeedbackSentView(
            warning: nil,
            onDismiss: { didDismiss = true },
            onSendMore: { didSendMore = true }
        )
        view.onDismiss?()
        #expect(didDismiss)
        view.onSendMore()
        #expect(didSendMore)
    }

    // MARK: - FeedbackComposerView body evaluation across states

    @Test @MainActor func composerEvaluatesBodyInSentSuccessState() {
        let client = makeClient()
        var didDismiss = false
        let result = makeSubmissionResult()
        let composer = FeedbackComposerView(
            client: client,
            initialResult: result,
            onDismiss: { didDismiss = true }
        )
        #expect(composer.dismissalAffordance == .done)
        _ = composer.body
    }

    @Test @MainActor func composerStaysUndeterminedWhileResolvingUnderDeniedConfig() {
        // Issue #367: with anonymous feedback denied and the access verdict
        // not yet resolved (the production presentation state on appearance),
        // the composer starts in its neutral loading state — never the denial
        // placeholder a signed-in user would see flash before `.task`
        // resolves.
        let client = makeClient(authenticationProvider: { "signed-in-jwt" })
        let deniedConfig = makeConfig(allowAnonymousFeedback: false)
        let composer = FeedbackComposerView(
            client: client,
            config: deniedConfig
        )
        #expect(composer.dismissalAffordance == .undetermined)
        #expect(composer.dismissalAffordance != .cancel)
        _ = composer.body
    }

    @Test @MainActor func composerShowsFormForAuthenticatedClientUnderDeniedConfig() {
        // A resolved bearer token satisfies the anonymous-feedback preflight;
        // the server stays authoritative (issue #233). View-level tests inject
        // the settled verdict instead of awaiting `.task` (issue #297).
        let client = makeClient(authenticationProvider: { "signed-in-jwt" })
        let deniedConfig = makeConfig(allowAnonymousFeedback: false)
        let composer = FeedbackComposerView(
            client: client,
            config: deniedConfig,
            preResolvedAuthentication: true
        )
        #expect(composer.dismissalAffordance == .guardedCancel)
        _ = composer.body
    }

    @Test @MainActor func composerStaysDeniedForSignedOutClientUnderDeniedConfig() {
        // An installed provider that answers `nil` (signed out) does not
        // satisfy the preflight: once the verdict settles on *no* access, the
        // denial placeholder with Cancel stays up instead of a form that can
        // only fail at submit (issue #297).
        let client = makeClient(authenticationProvider: { nil })
        var didDismiss = false
        let deniedConfig = makeConfig(allowAnonymousFeedback: false)
        let composer = FeedbackComposerView(
            client: client,
            config: deniedConfig,
            preResolvedAuthentication: false,
            onDismiss: { didDismiss = true }
        )
        #expect(composer.dismissalAffordance == .cancel)
        _ = composer.body
        #expect(!didDismiss)
    }

    @Test @MainActor func composerEvaluatesBodyInPlatformNotAllowedState() {
        let client = makeClient()
        var didDismiss = false
        let deniedConfig = makeConfig(
            allowedPlatforms: [],
            allowedPlatformValues: ["android"],
            allowAnonymousFeedback: true
        )
        let composer = FeedbackComposerView(
            client: client,
            config: deniedConfig,
            onDismiss: { didDismiss = true }
        )
        #expect(composer.dismissalAffordance == .cancel)
        _ = composer.body
    }

    @Test @MainActor func composerEvaluatesBodyInPermittedState() {
        let client = makeClient()
        let permittedConfig = makeConfig(allowAnonymousFeedback: true)
        let composer = FeedbackComposerView(
            client: client,
            config: permittedConfig
        )
        #expect(composer.dismissalAffordance == .guardedCancel)
        _ = composer.body
    }

    @Test @MainActor func composerFailsOpenWhenConfigIsNil() {
        let client = makeClient()
        let composer = FeedbackComposerView(client: client)
        #expect(composer.dismissalAffordance == .guardedCancel)
        _ = composer.body
    }

    // MARK: - Extracted Support Views Evaluation

    @Test @MainActor func attachmentRowEvaluatesAndFiresRemove() {
        var didRemove = false
        let attachment = FeedbackAttachment(
            kind: .image,
            uploadId: "upl-1",
            key: "att-1",
            url: URL(string: "https://example.com/screenshot.png")!,
            filename: "screenshot.png",
            mimeType: "image/png",
            size: 2048
        )
        let row = FeedbackAttachmentRowView(attachment: attachment) {
            didRemove = true
        }
        _ = row.body
        row.onRemove()
        #expect(didRemove)
    }

    #if canImport(PhotosUI) && !os(tvOS)
    @Test @MainActor func uploadingRowEvaluatesAndFiresCancel() {
        var didCancel = false
        let row = FeedbackUploadingAttachmentRowView {
            didCancel = true
        }
        _ = row.body
        row.onCancel()
        #expect(didCancel)
    }
    #endif

    @Test @MainActor func submitBarEvaluatesAndFiresSubmit() {
        var didSubmit = false
        let bar = FeedbackSubmitBarView(
            isSubmitting: false,
            canSubmit: true
        ) {
            didSubmit = true
        }
        _ = bar.body
        bar.onSubmit()
        #expect(didSubmit)
    }
}
