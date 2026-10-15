import Foundation

// MARK: - Surface load state

/// Loading lifecycle shared by the SDK's simple single-fetch surfaces —
/// ``CommentsView`` and ``UserProfileView`` (CONC-4): the loading flag, the
/// latest full-screen error, and a monotonic generation counter that
/// discards stale out-of-order writes.
///
/// A superseded load must not write behind newer data. A cancelled load
/// has no result to display, so it retains the loading presentation until
/// a replacement load settles or the surface disappears.
/// ``isCurrent(generation:)`` gates state writes, and
/// ``finishLoading(generation:wasCancelled:)`` settles only the current,
/// non-cancelled generation.
struct SurfaceLoadState: Equatable, Sendable {
    /// Whether the surface is waiting for a resolved load outcome.
    var isLoading: Bool
    /// User-friendly message when the latest failure had nothing to show.
    var loadError: String?
    /// Monotonically increasing counter; writes from a stale generation are
    /// discarded.
    var loadGeneration: Int

    /// Creates the lifecycle state.
    /// - Parameters:
    ///   - isLoading: Whether a fetch is currently in flight. Defaults to
    ///     `true` so a freshly presented surface renders its loading state
    ///     until the first `.task` load settles.
    ///   - loadError: Initial error message. Defaults to `nil`.
    ///   - loadGeneration: Initial generation counter. Defaults to `0`.
    init(
        isLoading: Bool = true,
        loadError: String? = nil,
        loadGeneration: Int = 0
    ) {
        self.isLoading = isLoading
        self.loadError = loadError
        self.loadGeneration = loadGeneration
    }

    /// Starts a load cycle: bumps the generation, marks the surface loading,
    /// and clears any previous full-screen error. Returns the generation to
    /// pass to ``finishLoading(generation:wasCancelled:)`` and check with
    /// ``isCurrent(generation:)`` around every write.
    @discardableResult
    mutating func startLoading() -> Int {
        loadGeneration += 1
        isLoading = true
        loadError = nil
        return loadGeneration
    }

    /// Settles a completed load. Cancellation leaves the loading presentation
    /// intact; a superseded generation cannot change the newer load's state.
    mutating func finishLoading(generation: Int, wasCancelled: Bool = false) {
        guard loadGeneration == generation, !wasCancelled else { return }
        isLoading = false
    }

    /// Whether `generation` is still the current load cycle. Success and
    /// failure writes must be gated on this so a superseded run cannot
    /// clobber the newer run's content.
    func isCurrent(generation: Int) -> Bool {
        loadGeneration == generation
    }
}
