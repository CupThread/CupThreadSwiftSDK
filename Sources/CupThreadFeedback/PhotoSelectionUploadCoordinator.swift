import Foundation
import Observation

/// Orchestrates the photo picker's selection → upload flow for
/// ``FeedbackComposerView``.
///
/// The picker selection is only a trigger. `PhotosPickerItem` equality is
/// based on the underlying library asset, so a selection that outlives its
/// upload attempt would make re-picking the same photo a silent no-op — most
/// importantly, a failed upload could never be retried with the same photo.
/// The coordinator therefore clears the selection after every terminal path
/// (success, failure, cancellation, supersede); in-flight progress is shown
/// by the uploading row instead of the selection.
@Observable
@MainActor
final class PhotoSelectionUploadCoordinator<Item: Equatable & Sendable> {
    /// The picker's current selection. `nil` between attempts: cleared after
    /// every terminal upload path so the picker is armed for a fresh pick.
    private(set) var selection: Item?

    private var uploadTask: Task<Void, Never>?

    /// Creates a coordinator with no selection and no in-flight upload.
    init() {}

    /// Mirrors a picker-reported cleared selection without touching the
    /// upload lifecycle (the user deselected inside the picker).
    func clearSelection() {
        selection = nil
    }

    /// Records a fresh selection and starts its upload attempt.
    ///
    /// Any in-flight attempt is cancelled first (supersede). The selection is
    /// cleared when the attempt reaches a terminal state — success, failure,
    /// or cancellation — so re-picking the same photo re-triggers the flow.
    ///
    /// - Parameters:
    ///   - item: The newly picked item.
    ///   - startUpload: Starts the upload on the attachment state machine and
    ///     returns its tracking id.
    ///   - upload: Runs the attempt to a terminal state (success, failure, or
    ///     cancellation) before returning; the selection is cleared right
    ///     after.
    /// - Returns: The attempt's task, so callers can re-point a
    ///   ``FeedbackUploadHandle`` at it.
    @discardableResult
    func select(
        _ item: Item,
        startUpload: () -> UUID,
        upload: @escaping (Item, UUID) async -> Void
    ) -> Task<Void, Never> {
        selection = item
        uploadTask?.cancel()
        let uploadId = startUpload()
        let task = Task { [weak self] in
            await upload(item, uploadId)
            // The selection is only a trigger: clear it on every terminal
            // path. Guarded so a superseding pick's selection is never
            // clobbered by this attempt's unwind.
            if let self, self.selection == item {
                self.selection = nil
            }
        }
        uploadTask = task
        return task
    }

    /// Cancels the in-flight attempt, if any, and clears the selection.
    ///
    /// Called at explicit, user-intent-bearing points: the uploading row's
    /// cancel button and the form reset after a successful submit.
    func cancel() {
        uploadTask?.cancel()
        uploadTask = nil
        selection = nil
    }
}
