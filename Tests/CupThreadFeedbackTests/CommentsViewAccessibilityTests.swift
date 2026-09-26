import Foundation
import SwiftUI
import Testing
@testable import CupThreadFeedback

@Suite("CommentsView Accessibility")
struct CommentsViewAccessibilityTests {
    @MainActor
    @Test func submitAccessibilityLabelIsLocalized() {
        let label = CommentsView.submitAccessibilityLabel()
        #expect(label == CupThreadStrings.tr("cupthread.comments.submit"))
        #expect(!label.isEmpty)
        #expect(label != "cupthread.comments.submit")
    }

    @MainActor
    @Test func cancelReplyAccessibilityLabelIsLocalized() {
        let label = CommentsView.cancelReplyAccessibilityLabel()
        #expect(label == CupThreadStrings.tr("cupthread.comments.cancel_reply"))
        #expect(!label.isEmpty)
        #expect(label != "cupthread.comments.cancel_reply")
    }

    @MainActor
    @Test func replyAccessibilityLabelIncludesTargetAuthor() {
        let label = CommentsView.replyAccessibilityLabel(targetAuthor: "Ada")
        #expect(label == CupThreadStrings.tr("cupthread.comments.reply_to_author", "Ada"))
        #expect(label.contains("Ada"))
        #expect(!label.contains("%@"))

        let anonymous = CupThreadStrings.tr("cupthread.features.anonymous")
        let anonLabel = CommentsView.replyAccessibilityLabel(targetAuthor: anonymous)
        #expect(anonLabel.contains(anonymous))
        #expect(!anonLabel.contains("%@"))
    }

    @MainActor
    @Test func viewProfileAccessibilityLabelIncludesAuthorHandle() {
        let label = CommentsView.viewProfileAccessibilityLabel(authorName: "adalovelace")
        #expect(label == CupThreadStrings.tr("cupthread.comments.view_profile_of", "adalovelace"))
        #expect(label.contains("@adalovelace"))
        #expect(!label.contains("%@"))
    }

    @MainActor
    @Test func commentsViewBodyEvaluatesWithoutErrors() {
        let client = makeClient()
        let view = CommentsView(
            client: client,
            userToken: "token_123",
            featureRequestId: "fr_123",
            featureRequestTitle: "Title"
        )
        _ = view.body
    }

    @MainActor
    @Test func moderatedCommentReplyTagRendersNonInteractiveLabelAndNeverProfileButton() {
        let client = makeClient()
        let view = CommentsView(
            client: client,
            userToken: "token_123",
            featureRequestId: "fr_123",
            featureRequestTitle: "Title"
        )

        let hiddenCommentWithReply = FeatureRequestComment(
            id: "c-hidden-reply",
            featureRequestId: "fr_123",
            authorName: "RudeUser",
            body: "Violating content",
            parentId: "c-parent",
            replyToClerkId: "clerk_parent_target",
            replyToAuthorName: "TargetAuthor",
            isHidden: true,
            createdAt: "2026-01-01T00:00:00.000Z"
        )

        let display = hiddenCommentWithReply.displayModel
        #expect(display.isModerated == true)
        #expect(display.replyToClerkId == nil)
        #expect(display.canOpenReplyToProfile == false)
        #expect(CommentsView.replyTagPresentation(for: display) == .label(authorName: "TargetAuthor"))

        _ = view.replyTag(for: display)
        _ = view.commentRow(hiddenCommentWithReply)
    }

    @MainActor
    @Test func visibleCommentReplyTagRendersProfileButtonWhenClerkIdPresent() {
        let client = makeClient()
        let view = CommentsView(
            client: client,
            userToken: "token_123",
            featureRequestId: "fr_123",
            featureRequestTitle: "Title"
        )

        let visibleCommentWithReply = FeatureRequestComment(
            id: "c-visible-reply",
            featureRequestId: "fr_123",
            authorName: "HelpfulUser",
            body: "Great point!",
            parentId: "c-parent",
            replyToClerkId: "clerk_parent_target",
            replyToAuthorName: "TargetAuthor",
            isHidden: false,
            createdAt: "2026-01-01T00:00:00.000Z"
        )

        let display = visibleCommentWithReply.displayModel
        #expect(display.isModerated == false)
        #expect(display.replyToClerkId == "clerk_parent_target")
        #expect(display.canOpenReplyToProfile == true)
        #expect(
            CommentsView.replyTagPresentation(for: display) ==
            .profileButton(clerkId: "clerk_parent_target", authorName: "TargetAuthor")
        )

        _ = view.replyTag(for: display)
        _ = view.commentRow(visibleCommentWithReply)
    }

    @MainActor
    @Test func visibleCommentReplyTagRendersPlainLabelWhenClerkIdMissing() {
        let anonTargetComment = FeatureRequestComment(
            id: "c-anon-target",
            featureRequestId: "fr_123",
            body: "Replying to anonymous",
            replyToClerkId: nil,
            replyToAuthorName: "Anonymous",
            isHidden: false,
            createdAt: "2026-01-01T00:00:00.000Z"
        )

        let display = anonTargetComment.displayModel
        #expect(display.replyToClerkId == nil)
        #expect(display.canOpenReplyToProfile == false)
        #expect(CommentsView.replyTagPresentation(for: display) == .label(authorName: "Anonymous"))
    }

    @MainActor
    @Test func commentWithoutReplyTargetProducesNoReplyTag() {
        let topLevelComment = FeatureRequestComment(
            id: "c-top-level",
            featureRequestId: "fr_123",
            body: "Top level comment",
            isHidden: false,
            createdAt: "2026-01-01T00:00:00.000Z"
        )

        let display = topLevelComment.displayModel
        #expect(CommentsView.replyTagPresentation(for: display) == .none)
    }
}
