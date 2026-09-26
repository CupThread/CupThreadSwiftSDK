import Foundation
import Testing
@testable import CupThreadFeedback

@Suite("FeedbackSubmissionWarning")
struct FeedbackSubmissionWarningTests {
    private let htmlWarning = "<html><body><h1>502 Bad Gateway</h1><pre>Traceback at /var/www/internal.py</pre></body></html>"

    @Test func attachmentSigningUnconfiguredResolvesLocalizedMessage() {
        let message = FeedbackSubmissionWarning.message(
            code: FeedbackSubmissionWarning.attachmentSigningUnconfigured
        )
        let expected = CupThreadStrings.tr("cupthread.feedback.warning_attachment_signing_unconfigured")
        #expect(message == expected)
        #expect(message != "cupthread.feedback.warning_attachment_signing_unconfigured")
        #expect(message?.isEmpty == false)
    }

    @Test func attachmentSigningUnconfiguredWithRawServerWarningNeverLeaksServerText() {
        let message = FeedbackSubmissionWarning.message(
            code: FeedbackSubmissionWarning.attachmentSigningUnconfigured,
            warning: htmlWarning
        )
        let expected = CupThreadStrings.tr("cupthread.feedback.warning_attachment_signing_unconfigured")
        #expect(message == expected)
        #expect(message?.contains("<") == false)
        #expect(message?.contains("html") == false)
        #expect(message?.contains("Traceback") == false)
        #expect(message?.contains("502") == false)
    }

    @Test func unknownWarningCodeResolvesGenericFallback() {
        let message = FeedbackSubmissionWarning.message(
            code: "unknown_future_warning_code",
            warning: htmlWarning
        )
        let expected = CupThreadStrings.tr("cupthread.feedback.warning_generic")
        #expect(message == expected)
        #expect(message?.contains("<") == false)
        #expect(message?.contains("Traceback") == false)
    }

    @Test func rawWarningWithoutCodeResolvesGenericFallbackAndHidesRawText() {
        let message = FeedbackSubmissionWarning.message(
            code: nil,
            warning: htmlWarning
        )
        let expected = CupThreadStrings.tr("cupthread.feedback.warning_generic")
        #expect(message == expected)
        #expect(message?.contains("<") == false)
        #expect(message?.contains("html") == false)
        #expect(message?.contains("502") == false)
    }

    @Test func nilOrEmptyCodeAndWarningResolvesNil() {
        #expect(FeedbackSubmissionWarning.message(code: nil, warning: nil) == nil)
        #expect(FeedbackSubmissionWarning.message(code: "", warning: "") == nil)
        #expect(FeedbackSubmissionWarning.message(code: "   ", warning: " \n\t ") == nil)
    }

    @Test func convenienceMethodMapsFeedbackSubmissionResult() {
        let result = FeedbackSubmissionResult(
            submissionId: "sub-warning-1",
            warning: htmlWarning,
            warningCode: FeedbackSubmissionWarning.attachmentSigningUnconfigured
        )
        // Raw diagnostic server text remains accessible on the model for host logging
        #expect(result.warning == htmlWarning)
        #expect(result.warningCode == FeedbackSubmissionWarning.attachmentSigningUnconfigured)

        // UI mapper strictly resolves curated localized copy
        let message = FeedbackSubmissionWarning.message(for: result)
        let expected = CupThreadStrings.tr("cupthread.feedback.warning_attachment_signing_unconfigured")
        #expect(message == expected)
        #expect(message?.contains("<") == false)
        #expect(message?.contains("Traceback") == false)
    }

    @MainActor
    @Test func sentViewSanitizesRawWarningThroughWarningCode() {
        let view = FeedbackSentView(
            warning: htmlWarning,
            warningCode: FeedbackSubmissionWarning.attachmentSigningUnconfigured,
            onSendMore: {}
        )
        let expected = CupThreadStrings.tr("cupthread.feedback.warning_attachment_signing_unconfigured")
        #expect(view.warning == expected)
        #expect(view.warning?.contains("<") == false)
        #expect(view.warning?.contains("html") == false)
        _ = view.body
    }

    @MainActor
    @Test func sentViewWithoutWarningCodeSanitizesRawWarningToGenericFallback() {
        let view = FeedbackSentView(
            warning: htmlWarning,
            onSendMore: {}
        )
        let expected = CupThreadStrings.tr("cupthread.feedback.warning_generic")
        #expect(view.warning == expected)
        #expect(view.warning?.contains("<") == false)
        _ = view.body
    }

    @MainActor
    @Test func sentViewWithNilWarningYieldsNilWarningBanner() {
        let view = FeedbackSentView(
            warning: nil,
            warningCode: nil,
            onSendMore: {}
        )
        #expect(view.warning == nil)
        _ = view.body
    }

    @MainActor
    @Test func sentViewDirectWarningMessageInitialization() {
        let view = FeedbackSentView(
            warningMessage: "Custom Curated Message",
            onSendMore: {}
        )
        #expect(view.warning == "Custom Curated Message")
        _ = view.body
    }
}
