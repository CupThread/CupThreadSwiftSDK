import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Spool admission policy (#423)

/// Pins the composer's post-spool admission policy: an upload whose
/// preparation awaited (photo load, transcode, temp-file write) while a
/// cancellation or a superseding selection landed must not hand its spooled
/// temp file to the network path. `FeedbackComposerView.preparePhotoForUpload`
/// and `uploadPhotoItem` share this decision table.
@Suite("PhotoUploadAdmission")
struct PhotoUploadAdmissionTests {

    @Test func activeUploadProceedsToTheNetwork() {
        #expect(
            PhotoUploadAdmission.resolve(isCancelled: false, isActiveUpload: true) == .proceed
        )
    }

    @Test func cancellationWhileStillActiveDemandsMachineReset() {
        // A FeedbackUploadHandle cancel leaves the state machine pointing at
        // this upload; only the unwind can reset it (issue #47's contract).
        #expect(
            PhotoUploadAdmission.resolve(isCancelled: true, isActiveUpload: true)
                == .cancelledWhileActive
        )
    }

    @Test func supersededUploadBailsOutSilently() {
        // The machine was re-pointed by a newer selection — resetting here
        // would tear down the newer upload's tracking.
        #expect(
            PhotoUploadAdmission.resolve(isCancelled: false, isActiveUpload: false) == .superseded
        )
        #expect(
            PhotoUploadAdmission.resolve(isCancelled: true, isActiveUpload: false) == .superseded
        )
    }

    // MARK: Spooled temp-file lifecycle

    @Test func spooledFileRoundTripsThroughTheDocumentedCleanup() async throws {
        // The cleanup the admission gates rely on: ownership is explicit —
        // a spooled file only disappears when its owner removes it.
        let fileURL = try await PhotoAttachmentHelper.makeTempUploadFile(
            Data(repeating: 0x41, count: 1024),
            fileExtension: "jpg",
            id: UUID()
        )
        #expect(FileManager.default.fileExists(atPath: fileURL.path()))

        PhotoAttachmentHelper.removeTempUploadFile(at: fileURL)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path()))

        // Best-effort removal tolerates a repeated call.
        PhotoAttachmentHelper.removeTempUploadFile(at: fileURL)
    }

    // MARK: Gate placement in the upload flow

    /// Reads a SDK source file relative to this test file, walking up to the
    /// package root (Swift Testing `#filePath` lands deep in DerivedData).
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

    @Test func preparationRevalidatesAndCleansUpAfterTheSpool() throws {
        // The temp-file write runs across awaits; without a post-spool gate,
        // a cancelled or superseded preparation leaks its spooled file and a
        // later refactor could silently drop the cleanup (issue #423).
        let content = try readSource("FeedbackComposerView.swift")

        let spoolCall = try #require(
            content.range(of: "PhotoAttachmentHelper.makeTempUploadFile("),
            "the spool call in preparePhotoForUpload not found"
        )
        let preparedReturn = try #require(
            content.range(of: "return PreparedPhotoUpload(", range: spoolCall.upperBound..<content.endIndex),
            "the prepared-value return not found after the spool call"
        )
        let postSpool = content[spoolCall.upperBound..<preparedReturn.lowerBound]
        #expect(
            postSpool.contains("PhotoUploadAdmission.resolve("),
            "the spool must be followed by an admission gate re-validating cancellation and the active upload (issue #423)"
        )
        #expect(
            postSpool.contains("PhotoAttachmentHelper.removeTempUploadFile(at: fileURL)"),
            "a doomed preparation must remove its spooled file before returning or throwing (issue #423)"
        )
        #expect(
            postSpool.contains("throw CancellationError()"),
            "a cancelled-but-still-active preparation must unwind through the catch path so the machine resets (issue #423)"
        )
    }

    @Test func uploadPathPreflightsAdmissionBeforeTheNetworkCall() throws {
        // Without the preflight, a superseded upload still creates a backend
        // upload session and streams obsolete bytes over the network
        // (issue #423).
        let content = try readSource("FeedbackComposerView.swift")

        let admission = try #require(
            content.range(of: "switch PhotoUploadAdmission.resolve("),
            "the upload-path admission preflight not found"
        )
        let networkCall = try #require(
            content.range(of: "client.uploadAttachment(", range: admission.upperBound..<content.endIndex),
            "the network upload call not found after the admission preflight"
        )
        let preflight = content[admission.upperBound..<networkCall.lowerBound]
        #expect(
            preflight.contains("case .cancelledWhileActive") && preflight.contains("case .superseded"),
            "the upload path must re-validate cancellation and the active upload before spending a session (issue #423)"
        )

        // `sendPreparedPhoto` owns the spooled file explicitly rather than
        // through `defer`: a Turnstile challenge can suspend the attempt while
        // the sheet is on screen, so the file must survive that hand-off and
        // be removed on each terminal branch instead (#53 Phase 2).
        let attempt = try #require(content.range(of: "private func sendPreparedPhoto"))
        let helper = try #require(
            content.range(of: "private func presentUploadChallenge", range: attempt.upperBound..<content.endIndex)
        )
        let attemptBody = content[attempt.upperBound..<helper.lowerBound]
        let attemptRemovals = attemptBody.components(
            separatedBy: "removeTempUploadFile(at: prepared.fileURL)"
        ).count - 1
        #expect(
            attemptRemovals >= 4,
            "every terminal attempt branch must remove the spooled file, found \(attemptRemovals)"
        )
        #expect(
            !attemptBody.contains("defer {"),
            "a defer would delete the spooled file while the challenge sheet is open"
        )

        let helperEnd = try #require(
            content.range(of: "private func recordUploadFailure", range: helper.upperBound..<content.endIndex)
        )
        let helperBody = content[helper.upperBound..<helperEnd.lowerBound]
        let handOffRemovals = helperBody.components(
            separatedBy: "removeTempUploadFile(at: prepared.fileURL)"
        ).count - 1
        #expect(handOffRemovals == 2, "challenge resume and cancel must both remove the spooled file")
    }
}
