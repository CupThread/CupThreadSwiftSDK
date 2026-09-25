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
}
