import Observation

/// Whether the server rejected the most recent load of a permission-gated
/// surface.
///
/// The verdict describes one load cycle: every new load re-tests the server,
/// so a rejection from an earlier cycle must not outlive the load that
/// received it (BUG-42, issue #523). This is a reference type so view-level
/// tests can observe mutations made outside a SwiftUI hierarchy, where
/// `@State` writes are not persisted.
@Observable
final class ServerRejectionLatch {
    /// Whether the current load cycle ended in a server-side rejection.
    private(set) var isRejected = false

    /// Starts a new load cycle, discarding the previous cycle's verdict.
    func beginLoadCycle() {
        isRejected = false
    }

    /// Records a server-side permission rejection for the current cycle.
    func reject() {
        isRejected = true
    }
}
