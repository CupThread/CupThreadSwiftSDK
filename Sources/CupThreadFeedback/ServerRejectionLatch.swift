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
    /// The load that recorded the current rejection. A versions load may
    /// clear only its own verdict; a list rejection survives until a list
    /// load starts, because versions does not fetch the list.
    private enum Source {
        case list
        case versions
    }

    /// Whether the current load cycle ended in a server-side rejection.
    private(set) var isRejected = false
    private var source: Source?

    /// Starts a list load, discarding any previous verdict.
    func beginListLoadCycle() {
        isRejected = false
        source = nil
    }

    /// Starts a versions load. A versions-owned verdict is re-tested; a
    /// list-owned rejection stays until a list load starts.
    func beginVersionsLoadCycle() {
        guard source != .list else { return }
        isRejected = false
        source = nil
    }

    /// Records a server-side permission rejection from a list load.
    func rejectList() {
        isRejected = true
        source = .list
    }

    /// Records a server-side permission rejection from a versions load. A
    /// list-owned rejection is never replaced by it.
    func rejectVersions() {
        guard source != .list else { return }
        isRejected = true
        source = .versions
    }
}
