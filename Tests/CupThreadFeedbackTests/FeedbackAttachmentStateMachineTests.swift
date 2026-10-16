import Foundation
import Testing
@testable import CupThreadFeedback

/// Regression coverage for issue #427: `FeedbackAttachmentStateMachine` must reject
/// non-positive attachment limits (`<= 0`) and fall back to the default limit,
/// ensuring that corrupted configs or bad parameters do not permanently block photo uploads.
@Suite("FeedbackAttachmentStateMachineTests")
struct FeedbackAttachmentStateMachineTests {
    @Test func nonPositiveInitLimitsFallbackToDefaultAndAcceptConfigLimit() {
        let zeroSM = FeedbackAttachmentStateMachine(maxAttachmentBytes: 0)
        #expect(zeroSM.maxAttachmentBytes == PhotoAttachmentHelper.defaultMaxAttachmentBytes)
        #expect(!zeroSM.hasExplicitLimit)
        #expect(zeroSM.usesConfigLimit)

        let negativeSM = FeedbackAttachmentStateMachine(maxAttachmentBytes: -1024)
        #expect(negativeSM.maxAttachmentBytes == PhotoAttachmentHelper.defaultMaxAttachmentBytes)
        #expect(!negativeSM.hasExplicitLimit)
        #expect(negativeSM.usesConfigLimit)
    }

    @Test func positiveInitLimitsArePreservedAndRejectConfigLimit() {
        var sm = FeedbackAttachmentStateMachine(maxAttachmentBytes: 5_000_000)
        #expect(sm.maxAttachmentBytes == 5_000_000)
        #expect(sm.hasExplicitLimit)
        #expect(!sm.usesConfigLimit)

        let applied = sm.applyConfigLimit(10_000_000)
        #expect(!applied)
        #expect(sm.maxAttachmentBytes == 5_000_000)
    }

    @Test func applyConfigLimitRejectsNonPositiveValues() {
        var stateMachine = FeedbackAttachmentStateMachine()
        let appliedZero = stateMachine.applyConfigLimit(0)
        #expect(!appliedZero)
        #expect(stateMachine.maxAttachmentBytes == PhotoAttachmentHelper.defaultMaxAttachmentBytes)

        let appliedNegative = stateMachine.applyConfigLimit(-500)
        #expect(!appliedNegative)
        #expect(stateMachine.maxAttachmentBytes == PhotoAttachmentHelper.defaultMaxAttachmentBytes)

        let appliedPositive = stateMachine.applyConfigLimit(10_000_000)
        #expect(appliedPositive)
        #expect(stateMachine.maxAttachmentBytes == 10_000_000)
    }
}
