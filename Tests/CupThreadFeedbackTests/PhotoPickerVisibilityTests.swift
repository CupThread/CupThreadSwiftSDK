import Foundation
import Testing
@testable import CupThreadFeedback

/// Pins the composer's photo-picker gate to the submission bound (issue
/// #633). The picker used to hide behind a bare `draft.attachments.count
/// < 5`: a literal that predates #613's named bound, counted on a different
/// figure — `attachments.count` charges legacy references the wire would
/// never see. The gate must stay the same comparison
/// `FeedbackAttachmentStateMachine/canSubmit(draft:)` makes —
/// `FeedbackSubmissionLimits.referencedUploadCount(in:)` against
/// `FeedbackSubmissionLimits/maxAttachmentCount` — so the built-in form
/// offers exactly the headroom the wire allows and picker exhaustion never
/// contradicts the submit gate.
@Suite("PhotoPickerVisibility")
struct PhotoPickerVisibilityTests {
    private static let cap = FeedbackSubmissionLimits.maxAttachmentCount

    /// The comparison the composer's `showsPhotoPicker` evaluates (pinned to
    /// the source by `composerGatesThePickerOnTheSubmissionBound`).
    private static func pickerOffered(_ draft: FeedbackDraft) -> Bool {
        FeedbackSubmissionLimits.referencedUploadCount(in: draft)
            < FeedbackSubmissionLimits.maxAttachmentCount
    }

    private static func attachment(_ index: Int, uploadId: String?) -> FeedbackAttachment {
        FeedbackAttachment(
            kind: .image,
            uploadId: uploadId,
            key: "key-\(index)",
            url: URL(string: "https://picker.example.com/api/v1/uploads/upl-\(index)")!,
            filename: "f\(index).png",
            mimeType: "image/png",
            size: 10
        )
    }

    /// A draft valid in every other respect, carrying `uploadCount`
    /// attachments with distinct upload ids followed by `legacyCount`
    /// legacy references without one.
    private static func draft(uploadCount: Int, legacyCount: Int = 0) -> FeedbackDraft {
        let uploaded = (0..<uploadCount).map { attachment($0, uploadId: "upl-\($0)") }
        let legacy = (0..<legacyCount).map { attachment(uploadCount + $0, uploadId: nil) }
        return FeedbackDraft(
            title: "Sync drops edits",
            description: "Editing while offline loses my last change.",
            platform: .ios,
            attachments: uploaded + legacy
        )
    }

    // MARK: The gate flips exactly at the bound

    @Test func pickerStaysOfferedOneBelowTheBound() {
        #expect(Self.pickerOffered(Self.draft(uploadCount: Self.cap - 1)))
    }

    @Test func pickerHidesAtTheBound() {
        #expect(!Self.pickerOffered(Self.draft(uploadCount: Self.cap)))
    }

    /// The composer previously hid the picker at five attachments while the
    /// wire cap is eight: the aligned gate must offer the documented
    /// headroom in between.
    @Test func pickerOffersTheHeadroomTheOldLiteralWithheld() {
        for count in 5..<Self.cap {
            #expect(Self.pickerOffered(Self.draft(uploadCount: count)), "\(count) uploads must still offer the picker")
        }
    }

    // MARK: The counting basis matches the wire

    /// A legacy reference without an `uploadId` never reaches the wire, so
    /// it must not consume a picker slot: more rows on screen than the bound,
    /// yet no forwarded id and the picker still offered. The old
    /// `attachments.count` gate hid the picker for this draft.
    @Test func legacyAttachmentCostsNoPickerSlot() {
        let draft = Self.draft(uploadCount: 0, legacyCount: Self.cap + 1)
        #expect(draft.attachments.count == Self.cap + 1)
        #expect(Self.pickerOffered(draft), "the wire would charge none of these rows")
    }

    /// One below the bound on the counted figure — even with legacy rows
    /// inflating `attachments.count` well past it — still offers the picker.
    @Test func legacyRowsDoNotPushADraftBelowTheBoundOverIt() {
        #expect(Self.pickerOffered(Self.draft(uploadCount: Self.cap - 1, legacyCount: 3)))
    }

    // MARK: Picker exhaustion never contradicts the submit gate

    /// When the composer stops offering the picker, the draft sits exactly
    /// at the wire cap — still submittable. The old mismatch could disable
    /// submit on a draft the picker had already stopped serving.
    @Test func pickerExhaustionLeavesTheDraftSubmittable() {
        let stateMachine = FeedbackAttachmentStateMachine()
        let atBound = Self.draft(uploadCount: Self.cap)
        #expect(!Self.pickerOffered(atBound))
        #expect(stateMachine.canSubmit(draft: atBound))
    }

    // MARK: The gate is wired in the composer source

    /// Reads an SDK source file relative to this test file, walking up to
    /// the package root (Swift Testing `#filePath` lands deep in
    /// DerivedData).
    private func readSource(_ name: String) throws -> String {
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

    @Test func composerGatesThePickerOnTheSubmissionBound() throws {
        let content = try readSource("FeedbackComposerView.swift")
        #expect(
            content.contains(
                "FeedbackSubmissionLimits.referencedUploadCount(in: draft) < FeedbackSubmissionLimits.maxAttachmentCount"
            ),
            "the picker gate must be the named bound counted on referenced uploads, mirroring canSubmit (issue #633)"
        )
        #expect(
            !content.contains("count < 5"),
            "the bare literal that predates the bound must stay gone (issue #633)"
        )
    }
}
