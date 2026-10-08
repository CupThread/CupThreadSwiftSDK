import Foundation

// MARK: - Surface load state

/// Loading lifecycle shared by the SDK's simple single-fetch surfaces —
/// ``CommentsView`` and ``UserProfileView`` (CONC-4): the loading flag, the
/// latest full-screen error, and a monotonic generation counter that
/// discards stale out-of-order writes.
///
/// A load can be superseded by a newer one (pull-to-refresh racing the
/// `.task` initial load, retry taps stacking up) or cancelled outright
/// (dismissal mid-fetch). Either way the superseded or cancelled run must
/// not write behind newer data or strand the surface on its spinner:
/// ``isCurrent(generation:)`` gates every state write, and
/// ``finishLoading(generation:)`` only clears `isLoading` for the
/// generation that still owns the surface — reached through the callers'
/// `defer`, so an early `return` on cancellation can no longer leave
/// `isLoading == true` forever.
struct SurfaceLoadState: Equatable, Sendable {
    /// Whether a fetch is currently in flight.
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
    /// pass to ``finishLoading(generation:)`` and check with
    /// ``isCurrent(generation:)`` around every write.
    @discardableResult
    mutating func startLoading() -> Int {
        loadGeneration += 1
        isLoading = true
        loadError = nil
        return loadGeneration
    }

    /// Ends the load cycle for `generation`. Runs from the caller's `defer`,
    /// so a cancelled run's early `return` still resets `isLoading`. A
    /// superseded load leaves the flag alone — the newer load owns it.
    mutating func finishLoading(generation: Int) {
        guard loadGeneration == generation else { return }
        isLoading = false
    }

    /// Whether `generation` is still the current load cycle. Success and
    /// failure writes must be gated on this so a superseded run cannot
    /// clobber the newer run's content.
    func isCurrent(generation: Int) -> Bool {
        loadGeneration == generation
    }
}
