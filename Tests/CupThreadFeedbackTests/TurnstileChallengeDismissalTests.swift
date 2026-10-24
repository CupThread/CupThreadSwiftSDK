import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Challenge settlement on dismissal (#539)

/// Pins the settlement contract behind `.turnstileChallengeSheet(_:)`: every
/// presented challenge must be answered exactly once, including when SwiftUI
/// dismisses the sheet without invoking Verified or Cancel. Before #539 that
/// interactive path dropped the only reference to the spooled photo and left
/// `FeedbackAttachmentStateMachine` parked in `.uploading`, so Send stayed
/// disabled until the user found the row's cancel button.
@Suite("Turnstile challenge dismissal")
struct TurnstileChallengeDismissalTests {
    static let presentation = TurnstileChallengePresentation(
        challenge: .feedback(appKey: "app_dismissal"),
        url: URL(string: "https://app.cupthread.test/turnstile/verify")!
    )

    /// The state machine is a value type; a box lets the MainActor challenge
    /// closures mutate the same instance the test inspects.
    @MainActor
    private final class MachineBox {
        var state = FeedbackAttachmentStateMachine()
    }

    private static func makeChallenge(
        resume: @escaping @MainActor (String) -> Void = { _ in },
        cancel: @escaping @MainActor () -> Void = {}
    ) -> PendingTurnstileChallenge {
        PendingTurnstileChallenge(
            presentation: presentation,
            resume: resume,
            cancel: cancel
        )
    }

    // MARK: Interactive dismissal

    @Test @MainActor func interactiveDismissalCancelsTheChallengeAndHealsTheUpload() async throws {
        // The cancel closure mirrors `presentUploadChallenge` exactly: delete
        // the spooled file, then let the machine record the terminal failure.
        let fileURL = try await PhotoAttachmentHelper.makeTempUploadFile(
            Data(repeating: 0x42, count: 512),
            fileExtension: "jpg",
            id: UUID()
        )
        let machine = MachineBox()
        let uploadId = machine.state.startUpload()
        var cancelCount = 0

        let challenge = Self.makeChallenge(
            resume: { _ in
                Issue.record("A dismissal must not resume the rejected call")
            },
            cancel: {
                cancelCount += 1
                PhotoAttachmentHelper.removeTempUploadFile(at: fileURL)
                if machine.state.activeUploadId == uploadId {
                    _ = machine.state.uploadFailed(
                        id: uploadId,
                        error: FeedbackClientError.turnstileRequired(message: nil, requestId: nil)
                    )
                }
            }
        )

        var settlement = TurnstileChallengeSettlement()
        settlement.register(challenge)

        // `sheet(item:)` nils the binding on a swipe-down without calling the
        // sheet's own buttons; `onDismiss` is the only hook that still runs.
        settlement.settleOnDismiss()?.cancel()

        #expect(cancelCount == 1)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path()))
        #expect(!machine.state.isUploading)

        let draft = FeedbackDraft(title: "Title", description: "Description", platform: .ios)
        #expect(machine.state.canSubmit(draft: draft))
        #expect(machine.state.currentErrorMessage != nil)
    }

    @Test @MainActor func dismissalAfterAnExplicitResolutionIsANoOp() {
        var settlement = TurnstileChallengeSettlement()
        settlement.register(Self.makeChallenge())

        settlement.settleOnDismiss()?.cancel()
        #expect(settlement.settleOnDismiss() == nil)
    }

    @Test @MainActor func dismissalWithoutAPresentationIsANoOp() {
        var settlement = TurnstileChallengeSettlement()
        #expect(settlement.settleOnDismiss() == nil)
    }

    @Test @MainActor func registrationKeepsTheFirstChallengeWhenASecondProducerArrives() {
        // A submission can still be in flight while a photo upload starts.
        // Replacing the registered challenge would drop the first attempt's
        // cleanup, so registration keeps the owner and the producers refuse
        // to present a second challenge (#539).
        var firstCancelCount = 0
        var secondCancelCount = 0
        var settlement = TurnstileChallengeSettlement()
        settlement.register(Self.makeChallenge(cancel: { firstCancelCount += 1 }))
        settlement.register(Self.makeChallenge(cancel: { secondCancelCount += 1 }))

        settlement.settleOnDismiss()?.cancel()

        #expect(firstCancelCount == 1)
        #expect(secondCancelCount == 0)
    }

    // MARK: Explicit paths run cancel/resume exactly once

    @Test @MainActor func explicitCancelResolvesBeforeTheDismissalHook() {
        var cancelCount = 0
        var resumeCount = 0
        let challenge = Self.makeChallenge(
            resume: { _ in resumeCount += 1 },
            cancel: { cancelCount += 1 }
        )
        var settlement = TurnstileChallengeSettlement()
        settlement.register(challenge)

        // The toolbar Cancel button: resolve, dismiss, then answer.
        settlement.resolve()
        challenge.cancel()
        // The `dismiss()` that follows still fires `onDismiss`.
        #expect(settlement.settleOnDismiss() == nil)

        #expect(cancelCount == 1)
        #expect(resumeCount == 0)
    }

    @Test @MainActor func verifiedResolvesBeforeTheDismissalHook() {
        var cancelCount = 0
        var resumeCount = 0
        let challenge = Self.makeChallenge(
            resume: { _ in resumeCount += 1 },
            cancel: { cancelCount += 1 }
        )
        var settlement = TurnstileChallengeSettlement()
        settlement.register(challenge)

        settlement.resolve()
        challenge.resume("tok-single-use")
        #expect(settlement.settleOnDismiss() == nil)

        #expect(resumeCount == 1)
        #expect(cancelCount == 0)
    }

    // MARK: Wiring

    /// Reads a SDK source file relative to this test file, walking up to the
    /// package root (Swift Testing `#filePath` lands deep in DerivedData).
    private static func source(_ name: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            directory.deleteLastPathComponent()
            let candidate = directory
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("CupThreadFeedback", isDirectory: true)
                .appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }

    @Test func modifierSettlesDismissalAndRegistersThePresentedChallenge() throws {
        let modifier = try Self.source("TurnstileChallengeModifier.swift")

        #expect(
            modifier.contains("sheet(item: $pending, onDismiss: settleOnDismiss)"),
            "the sheet must observe dismissal; `sheet(item:)` alone drops the challenge on a swipe (#539)"
        )
        #expect(modifier.contains("settlement.register(challenge)"))
        #expect(modifier.contains("settlement.settleOnDismiss()?.cancel()"))
    }

    @Test func sheetRefusesInteractiveDismissal() throws {
        let sheet = try Self.source("TurnstileChallengeSheet.swift")

        #expect(
            sheet.contains(".interactiveDismissDisabled()"),
            "a swipe-down must not strand the caller's pending challenge (#539)"
        )
    }

    @Test func composerRefusesASecondChallengeWhileOneIsPending() throws {
        let composer = try Self.source("FeedbackComposerView.swift")
        let submissionHelper = try #require(composer.range(of: "private func presentChallengeIfNeeded"))
        let uploadHelper = try #require(
            composer.range(of: "private func presentUploadChallenge", range: submissionHelper.upperBound..<composer.endIndex)
        )
        let submissionBody = composer[submissionHelper.upperBound..<uploadHelper.lowerBound]

        #expect(
            submissionBody.contains("guard pendingChallenge == nil else { return false }"),
            "a gated submission must not replace an upload's pending challenge (#539)"
        )

        let recordHelper = try #require(
            composer.range(of: "private func recordUploadFailure", range: uploadHelper.upperBound..<composer.endIndex)
        )
        let uploadBody = composer[uploadHelper.upperBound..<recordHelper.lowerBound]

        #expect(
            uploadBody.contains("guard pendingChallenge == nil else {"),
            "a gated upload must not replace a submission's pending challenge (#539)"
        )
        #expect(uploadBody.contains(
            "PhotoAttachmentHelper.removeTempUploadFile(at: prepared.fileURL)"
        ))
        #expect(uploadBody.contains("recordUploadFailure(error, uploadId: uploadId)"))
    }
}
