import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - State machine invariants behind the selection reset (#35)

/// The composer's pre-#35 reset guard (`attachmentState.activeUploadId ==
/// uploadId`, evaluated after the attempt had already returned) could never
/// hold: every terminal path of the state machine leaves `activeUploadId`
/// `nil`. These tests pin that invariant — the selection reset must never
/// depend on the attempt still being the active one.
@Suite("PhotoSelectionResetInvariants")
struct PhotoSelectionResetInvariantsTests {

    private func makeAttachment(key: String) -> FeedbackAttachment {
        FeedbackAttachment(kind: .image, key: key, url: URL(string: "https://example.com/\(key)")!)
    }

    @Test func successTerminalPathLeavesActiveUploadIdNil() {
        var machine = FeedbackAttachmentStateMachine()
        var draft = FeedbackDraft.autofilled(platform: .ios)
        let uploadId = machine.startUpload()
        #expect(machine.activeUploadId == uploadId)

        machine.uploadSucceeded(id: uploadId, attachment: makeAttachment(key: "ok"), draft: &draft)

        #expect(machine.activeUploadId == nil)
        #expect(!machine.isUploading)
    }

    @Test func failureTerminalPathLeavesActiveUploadIdNil() {
        var machine = FeedbackAttachmentStateMachine()
        let uploadId = machine.startUpload()
        #expect(machine.activeUploadId == uploadId)

        machine.uploadFailed(id: uploadId, error: NSError(domain: "test", code: 1))

        #expect(machine.activeUploadId == nil)
        #expect(!machine.isUploading)
        #expect(machine.currentErrorMessage != nil)
    }

    @Test func cancellationTerminalPathLeavesActiveUploadIdNil() {
        var machine = FeedbackAttachmentStateMachine()
        let uploadId = machine.startUpload()
        #expect(machine.activeUploadId == uploadId)

        machine.cancelUpload()

        #expect(machine.activeUploadId == nil)
        #expect(!machine.isUploading)
        #expect(machine.currentErrorMessage == nil)
    }
}

// MARK: - Selection → upload orchestration (#35)

/// Pins the composer's photo-picker orchestration: the selection is only a
/// trigger and is cleared after every terminal upload path (success, failure,
/// cancellation, supersede). `PhotosPickerItem` equality is asset-based, so a
/// selection that outlived its attempt would make re-picking the same photo a
/// silent no-op — most importantly, a failed upload could never be retried
/// with the same photo.
@Suite("PhotoSelectionUploadCoordinator")
struct PhotoSelectionUploadCoordinatorTests {

    /// Stand-in for `PhotosPickerItem`, whose equality is also value-based
    /// (underlying library asset) but which cannot be constructed in tests.
    private struct FakePhoto: Equatable, Sendable {
        let assetID: Int
    }

    /// MainActor-confined mutable box for values captured by the upload
    /// closures (escaping closures cannot capture mutable locals).
    @MainActor
    private final class TestBox<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    @MainActor
    @Test func freshCoordinatorHasNoSelection() {
        let coordinator = PhotoSelectionUploadCoordinator<FakePhoto>()
        #expect(coordinator.selection == nil)
    }

    // MARK: The fix: failed attempt re-arms the picker for the same photo

    @MainActor
    @Test func failedAttemptClearsSelectionAndSameItemCanBePickedAgain() async {
        let coordinator = PhotoSelectionUploadCoordinator<FakePhoto>()
        var machine = FeedbackAttachmentStateMachine()
        let draftBox = TestBox(FeedbackDraft.autofilled(platform: .ios))
        let invocations = TestBox(0)
        let photo = FakePhoto(assetID: 7)

        let firstAttempt = coordinator.select(
            photo,
            startUpload: { machine.startUpload() },
            upload: { _, uploadId in
                invocations.value += 1
                machine.uploadFailed(
                    id: uploadId,
                    error: NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "network down"])
                )
            }
        )
        await firstAttempt.value

        // The failed attempt cleared the selection …
        #expect(coordinator.selection == nil)
        #expect(!machine.isUploading)
        #expect(machine.currentErrorMessage == "network down")

        // … so re-picking the same photo re-triggers the flow (was a silent
        // no-op before #35).
        let secondAttempt = coordinator.select(
            photo,
            startUpload: { machine.startUpload() },
            upload: { _, uploadId in
                invocations.value += 1
                machine.uploadSucceeded(
                    id: uploadId,
                    attachment: FeedbackAttachment(
                        kind: .image, key: "retry", url: URL(string: "https://example.com/retry")!
                    ),
                    draft: &draftBox.value
                )
            }
        )
        await secondAttempt.value

        #expect(invocations.value == 2)
        #expect(coordinator.selection == nil)
        #expect(draftBox.value.attachments.count == 1)
    }

    // MARK: Success also re-arms the picker

    @MainActor
    @Test func successfulAttemptAppendsAttachmentAndClearsSelection() async {
        let coordinator = PhotoSelectionUploadCoordinator<FakePhoto>()
        var machine = FeedbackAttachmentStateMachine()
        let draftBox = TestBox(FeedbackDraft.autofilled(platform: .ios))

        let attempt = coordinator.select(
            FakePhoto(assetID: 5),
            startUpload: { machine.startUpload() },
            upload: { _, uploadId in
                machine.uploadSucceeded(
                    id: uploadId,
                    attachment: FeedbackAttachment(
                        kind: .image, key: "done", url: URL(string: "https://example.com/done")!
                    ),
                    draft: &draftBox.value
                )
            }
        )
        await attempt.value

        #expect(coordinator.selection == nil)
        #expect(!machine.isUploading)
        #expect(draftBox.value.attachments.count == 1)
    }

    // MARK: Cancellation re-arms the picker and discards the result

    @MainActor
    @Test func cancelMidUploadClearsSelectionAndDiscardsLateResult() async {
        let coordinator = PhotoSelectionUploadCoordinator<FakePhoto>()
        var machine = FeedbackAttachmentStateMachine()
        let draftBox = TestBox(FeedbackDraft.autofilled(platform: .ios))

        let attempt = coordinator.select(
            FakePhoto(assetID: 3),
            startUpload: { machine.startUpload() },
            upload: { _, uploadId in
                // Park until cancelled, like an in-flight network transfer.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                // Late server receipt racing the cancel: the view's
                // cancelUpload already reset the machine, so the receipt is
                // discarded and nothing lands in the draft.
                let accepted = machine.uploadSucceeded(
                    id: uploadId,
                    attachment: FeedbackAttachment(
                        kind: .image, key: "late", url: URL(string: "https://example.com/late")!
                    ),
                    draft: &draftBox.value
                )
                #expect(!accepted)
            }
        )

        // Let the attempt park, then press the uploading row's X button.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(machine.isUploading)

        coordinator.cancel()
        machine.cancelUpload()

        // Cleared immediately, not only after the unwind.
        #expect(coordinator.selection == nil)

        await attempt.value
        #expect(coordinator.selection == nil)
        #expect(draftBox.value.attachments.isEmpty)
        #expect(!machine.isUploading)
    }

    // MARK: Supersede keeps the newer selection

    @MainActor
    @Test func supersedingPickCancelsFirstAttemptAndPreservesSecondSelection() async {
        let coordinator = PhotoSelectionUploadCoordinator<FakePhoto>()
        var machine = FeedbackAttachmentStateMachine()

        let firstAttempt = coordinator.select(
            FakePhoto(assetID: 1),
            startUpload: { machine.startUpload() },
            upload: { _, _ in
                // Park until cancelled, like an in-flight network transfer.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
        )

        try? await Task.sleep(for: .milliseconds(100))
        #expect(coordinator.selection == FakePhoto(assetID: 1))

        let secondAttempt = coordinator.select(
            FakePhoto(assetID: 2),
            startUpload: { machine.startUpload() },
            upload: { _, _ in
                // Park until cancelled too, so it is still in flight when
                // the first attempt unwinds.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                machine.cancelUpload() // terminal state for the attempt
            }
        )

        // The first attempt's unwind must not clobber the second selection …
        await firstAttempt.value
        #expect(coordinator.selection == FakePhoto(assetID: 2))

        // … which is cleared when the second attempt reaches its own
        // terminal path.
        secondAttempt.cancel()
        await secondAttempt.value
        #expect(coordinator.selection == nil)
        #expect(!machine.isUploading)
    }

    // MARK: Picker-reported deselection only mirrors, never side-effects

    @MainActor
    @Test func clearSelectionMirrorsDeselectionWithoutTouchingTheUpload() async {
        let coordinator = PhotoSelectionUploadCoordinator<FakePhoto>()
        var machine = FeedbackAttachmentStateMachine()
        let invocations = TestBox(0)

        let attempt = coordinator.select(
            FakePhoto(assetID: 9),
            startUpload: { machine.startUpload() },
            upload: { _, _ in
                invocations.value += 1
            }
        )

        // Deselecting inside the picker clears the displayed selection but
        // neither starts nor cancels an upload.
        coordinator.clearSelection()
        #expect(coordinator.selection == nil)
        #expect(invocations.value == 0)
        #expect(machine.isUploading)

        await attempt.value
        // The attempt's own unwind is a no-op: nothing left to clear.
        #expect(coordinator.selection == nil)
    }
}
