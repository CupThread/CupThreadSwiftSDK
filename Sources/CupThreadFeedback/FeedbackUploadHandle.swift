import Foundation

/// A handle for cancelling a ``FeedbackComposerView``'s in-flight attachment
/// upload from outside the view hierarchy.
///
/// By design the composer never cancels uploads from view lifecycle events:
/// transient disappearances (`NavigationStack` push, `TabView` tab switches)
/// leave the upload running, and when the composer is dismissed entirely an
/// in-flight upload finishes in the background and its result is discarded.
/// Hosts that prefer to stop the transfer when the composer is really
/// dismissed create a handle, pass it to the composer's initializer, and call
/// ``cancelActiveUpload()`` from the presentation context's `onDismiss`:
///
/// ```swift
/// struct FeedbackSheet: View {
///     let client: FeedbackClient
///     @State private var isPresented = false
///     private let uploadHandle = FeedbackUploadHandle()
///
///     var body: some View {
///         Button("Send Feedback") { isPresented = true }
///             .sheet(isPresented: $isPresented, onDismiss: {
///                 uploadHandle.cancelActiveUpload()
///             }) {
///                 NavigationStack {
///                     FeedbackComposerView(client: client, uploadHandle: uploadHandle)
///                 }
///             }
///     }
/// }
/// ```
///
/// The composer re-points the handle at its current upload every time a new
/// upload starts. ``cancelActiveUpload()`` is safe to call at any time: with
/// no upload in flight it is a no-op, repeated calls do nothing once the
/// upload stopped, and a call never interferes with uploads started after it.
public final class FeedbackUploadHandle: Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var handler: (@Sendable () -> Void)?

    /// Creates an inactive upload handle.
    public init() {}

    /// Cancels the composer's in-flight attachment upload, if any.
    ///
    /// A no-op when the composer has no in-flight upload. Safe to call from
    /// any thread or actor, and safe to call repeatedly.
    public func cancelActiveUpload() {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?()
    }

    /// Points the handle at the composer's current upload task.
    ///
    /// Called by the composer whenever a new upload starts; the previous
    /// target is discarded, so cancelling after a new upload began only
    /// affects the newest upload.
    func setCancelHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }
}
