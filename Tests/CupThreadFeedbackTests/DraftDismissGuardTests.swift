import Foundation
import Testing
@testable import CupThreadFeedback

@Suite("Draft dismiss guard")
struct DraftDismissGuardTests {
    // MARK: - FeedbackDraft.hasContent

    @Suite("FeedbackDraft content detection")
    struct FeedbackDraftContentTests {
        @Test func emptyDraftHasNoContent() {
            let draft = FeedbackDraft(platform: .ios)
            #expect(!draft.hasContent)
        }

        @Test func autofilledDraftAloneHasNoContent() {
            // Environment pre-fill is not user content.
            let draft = FeedbackDraft.autofilled(platform: .ios)
            #expect(!draft.hasContent)
        }

        @Test func titleAloneCountsAsContent() {
            var draft = FeedbackDraft(platform: .ios)
            draft.title = "Export broken"
            #expect(draft.hasContent)
        }

        @Test func descriptionAloneCountsAsContent() {
            var draft = FeedbackDraft(platform: .ios)
            draft.description = "Steps to reproduce: ..."
            #expect(draft.hasContent)
        }

        @Test func contactFieldsAloneCountAsContent() {
            var draft = FeedbackDraft(platform: .ios)
            draft.reporterName = "Ada"
            #expect(draft.hasContent)

            var emailOnly = FeedbackDraft(platform: .ios)
            emailOnly.reporterEmail = "ada@example.com"
            #expect(emailOnly.hasContent)
        }

        @Test func attachmentsAloneCountAsContent() {
            let attachment = FeedbackAttachment(
                kind: .image,
                uploadId: "upload-1",
                key: "k",
                url: URL(string: "https://example.com/k")!
            )
            let draft = FeedbackDraft(platform: .ios, attachments: [attachment])
            #expect(draft.hasContent)
        }

        @Test func whitespaceOnlyFieldsHaveNoContent() {
            var draft = FeedbackDraft(platform: .ios)
            draft.title = "   \n\t"
            draft.description = "  "
            draft.reporterName = "\n"
            draft.reporterEmail = "\t "
            #expect(!draft.hasContent)
        }

        @Test func metadataAloneDoesNotCountAsContent() {
            var draft = FeedbackDraft(platform: .ios)
            draft.metadata = ["locale": "en_US"]
            #expect(!draft.hasContent)
        }
    }

    // MARK: - FeatureRequestDraft.hasContent

    @Suite("FeatureRequestDraft content detection")
    struct FeatureRequestDraftContentTests {
        @Test func emptyDraftHasNoContent() {
            #expect(!FeatureRequestDraft().hasContent)
        }

        @Test func eachFieldAloneCountsAsContent() {
            var title = FeatureRequestDraft()
            title.title = "Dark mode"
            #expect(title.hasContent)

            var description = FeatureRequestDraft()
            description.description = "Please add a dark theme."
            #expect(description.hasContent)

            var name = FeatureRequestDraft()
            name.requesterName = "Ada"
            #expect(name.hasContent)
        }

        @Test func whitespaceOnlyFieldsHaveNoContent() {
            var draft = FeatureRequestDraft()
            draft.title = " \t"
            draft.description = "\n "
            draft.requesterName = "   "
            #expect(!draft.hasContent)
        }
    }

    // MARK: - CommentDraft.hasContent

    @Suite("CommentDraft content detection")
    struct CommentDraftContentTests {
        @Test func emptyDraftHasNoContent() {
            #expect(!CommentDraft().hasContent)
        }

        @Test func bodyCountsAsContent() {
            var draft = CommentDraft()
            draft.body = "Great idea!"
            #expect(draft.hasContent)
        }

        @Test func whitespaceOnlyBodyHasNoContent() {
            var draft = CommentDraft()
            draft.body = "  \n "
            #expect(!draft.hasContent)
        }

        @Test func replyMetadataAloneDoesNotCountAsContent() {
            var draft = CommentDraft()
            draft.parentId = "c1"
            draft.replyToAuthorName = "Ada"
            draft.replyToClerkId = "user_1"
            #expect(!draft.hasContent)
        }
    }

    // MARK: - ComposerDismissalDecision

    @Suite("Dismissal decision")
    struct DismissalDecisionTests {
        @Test func emptyIdleComposerDismissesDirectly() {
            #expect(
                ComposerDismissalDecision.resolve(hasContent: false, isSubmitting: false) == .dismiss
            )
        }

        @Test func contentAlwaysRequiresConfirmation() {
            #expect(
                ComposerDismissalDecision.resolve(hasContent: true, isSubmitting: false) == .confirmDiscard
            )
        }

        @Test func inFlightSubmissionRequiresConfirmationEvenWithoutContent() {
            #expect(
                ComposerDismissalDecision.resolve(hasContent: false, isSubmitting: true) == .confirmDiscard
            )
        }

        @Test func contentPlusSubmissionRequiresConfirmation() {
            #expect(
                ComposerDismissalDecision.resolve(hasContent: true, isSubmitting: true) == .confirmDiscard
            )
        }
    }

    // MARK: - Localized discard prompts

    @Suite("Discard prompt localization")
    struct DiscardPromptLocalizationTests {
        @Test func discardTitlesResolveThroughModuleBundle() {
            for key in [
                "cupthread.feedback.discard_title",
                "cupthread.features.compose_discard_title",
                "cupthread.comments.discard_title"
            ] {
                let resolved = CupThreadStrings.tr(key)
                #expect(resolved != key, "Key \(key) fell back to the raw key")
                #expect(!resolved.isEmpty)
            }
        }

        @Test func discardActionButtonsResolveThroughModuleBundle() {
            for key in [
                "cupthread.common.cancel",
                "cupthread.common.discard",
                "cupthread.common.keep_editing"
            ] {
                let resolved = CupThreadStrings.tr(key)
                #expect(resolved != key, "Key \(key) fell back to the raw key")
                #expect(!resolved.isEmpty)
            }
        }
    }
}
