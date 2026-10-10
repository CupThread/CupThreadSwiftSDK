import Foundation

// MARK: - FeatureRequestsLoadState

/// Loading lifecycle for ``FeatureRequestsView``: the replacing-load generation
/// counter plus the two flags the list rendering branches on (`isLoading`,
/// `hasLoadedOnce`).
///
/// Invariant (mirroring the `WhatsNewViewState` fix for issue #196): only a
/// completed verdict of the newest, non-cancelled load may resolve the
/// lifecycle. A cancelled or superseded load never reached a verdict — it must
/// not clear `isLoading` (a newer load may still be fetching) and must not set
/// `hasLoadedOnce`, or the surface renders a fabricated "no requests" empty
/// state — and the skeleton stays suppressed — while the replacement load is
/// still in flight, or forever when the throttle skips that replacement.
struct FeatureRequestsLoadState: Equatable, Sendable {
    /// Whether a replacing load is currently in flight.
    private(set) var isLoading: Bool

    /// True once a load reached a completed verdict (results applied, or a
    /// non-cancellation failure mapped). Cancellation never marks this true,
    /// so the skeleton keeps rendering until a real verdict exists.
    private(set) var hasLoadedOnce: Bool

    /// Monotonically increasing counter; a verdict computed for an older
    /// generation is dropped instead of clobbering the newer load's state.
    private(set) var loadGeneration: Int

    /// Creates the lifecycle state. Loads start in flight (`isLoading`), so
    /// the first presentation renders the skeleton rather than the empty state.
    init(isLoading: Bool = true, hasLoadedOnce: Bool = false) {
        self.isLoading = isLoading
        self.hasLoadedOnce = hasLoadedOnce
        self.loadGeneration = 0
    }

    /// Begins a replacing load: bumps the generation, marks the surface
    /// loading, and returns the generation the caller must pass back to
    /// ``finishLoading(generation:wasCancelled:)``.
    @discardableResult
    mutating func startLoading() -> Int {
        loadGeneration += 1
        isLoading = true
        return loadGeneration
    }

    /// Resolves the lifecycle after `generation` reached a verdict (its page
    /// applied or its failure mapped).
    ///
    /// A load whose task was cancelled, or whose generation a newer load has
    /// replaced, never reached a verdict: nothing is written, so the indicator
    /// and skeleton ownership stay with the load that is actually current.
    mutating func finishLoading(generation: Int, wasCancelled: Bool) {
        guard loadGeneration == generation, !wasCancelled else { return }
        isLoading = false
        hasLoadedOnce = true
    }

    /// Settles the lifecycle for a permission denial (issue #363): the list
    /// is no longer first-loading, and the generation bump invalidates any
    /// in-flight permitted load so its success/failure writes cannot land
    /// behind the permission placeholder.
    mutating func settlePermissionDenied() {
        loadGeneration += 1
        isLoading = false
        hasLoadedOnce = true
    }
}
