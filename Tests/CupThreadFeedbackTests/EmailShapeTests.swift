import Foundation
import Testing
@testable import CupThreadFeedback

/// The shared email plausibility helper (#283) and the two surfaces built on
/// it: the changelog subscribe sheet's hard gate and the feedback composer's
/// non-blocking contact-email hint.
@Suite("Email shape")
struct EmailShapeTests {
    // MARK: - Shared plausibility matrix (issue #283 acceptance set)

    @Test func plausibilityMatrix() {
        let plausible = [
            "user@example.com",
            "  user@example.com  ",  // trimmed before checking
            "u@example.io",
            "user+tag@example.co.uk"  // multi-label domain
        ]
        for candidate in plausible {
            #expect(EmailShape.isPlausible(candidate), "Expected plausible: \(candidate)")
        }

        let implausible = [
            "user@@example.com",  // multiple @ (#281)
            "user@host",  // no dot after the @
            "user@host.",  // trailing-dot domain label (#281)
            "user@example..com",  // empty domain label (#281)
            "user@.example.com",  // leading empty domain label
            "@example.com",  // missing local part
            "user@",  // missing domain
            "@",
            "not-an-email",
            "\"user name@example.com\"",  // embedded whitespace
            "user name@example.com",
            " "  // whitespace-only counts as empty
        ]
        for candidate in implausible {
            #expect(!EmailShape.isPlausible(candidate), "Expected implausible: \(candidate)")
        }
    }

    /// The check stays lightweight: IDN-style addresses are plausible here and
    /// full validation remains the server's job.
    @Test func nonASCIIDomainsRemainPlausible() {
        #expect(EmailShape.isPlausible("user@münchen.de"))
        #expect(EmailShape.isPlausible("用户@例子.公司"))
    }

    // MARK: - Changelog subscribe sheet (hardened gate)

    /// The subscribe sheet now rejects the malformed shapes #281 documented
    /// while keeping its existing valid-input behavior intact.
    @Test func subscribeModelRejectsHardenedShapes() {
        var model = ChangelogSubscribeModel(subscribedEmail: nil)

        model.email = "user@@example.com"
        #expect(!model.isValidEmail)
        #expect(model.isPrimaryDisabled)

        model.email = "user@host."
        #expect(!model.isValidEmail)
        #expect(model.isPrimaryDisabled)

        model.email = "user@example..com"
        #expect(!model.isValidEmail)
        #expect(model.isPrimaryDisabled)

        model.email = "  user@example.com  "
        #expect(model.isValidEmail)
        #expect(!model.isPrimaryDisabled)
    }

    // MARK: - Feedback composer (non-blocking hint)

    /// The hint state is exposed only for non-empty input that fails the
    /// plausibility check — empty and plausible addresses stay hint-free.
    @Test func composerHintFollowsEmptyPlausibleImplausible() {
        #expect(!FeedbackComposerView.showsContactEmailHint(""))
        #expect(!FeedbackComposerView.showsContactEmailHint("   "))
        #expect(!FeedbackComposerView.showsContactEmailHint("user@example.com"))
        #expect(!FeedbackComposerView.showsContactEmailHint("  user@example.com  "))
        #expect(FeedbackComposerView.showsContactEmailHint("user@@example.com"))
        #expect(FeedbackComposerView.showsContactEmailHint("user@host"))
        #expect(FeedbackComposerView.showsContactEmailHint("user name@example.com"))
    }

    /// The hint is advisory only: an implausible-but-present contact email
    /// never disables submission (issue #283's non-blocking requirement) —
    /// the server stays authoritative and the field is optional.
    @Test func implausibleEmailKeepsSubmitEnabled() {
        let stateMachine = FeedbackAttachmentStateMachine()
        let draft = FeedbackDraft(
            title: "Valid title",
            description: "Valid description longer than 5 chars",
            reporterEmail: "user@@example.com",
            platform: .ios
        )
        #expect(FeedbackComposerView.showsContactEmailHint(draft.reporterEmail))
        #expect(stateMachine.canSubmit(draft: draft), "A broken contact email must not block submission")
    }
}
