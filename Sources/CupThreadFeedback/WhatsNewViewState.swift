import Foundation

// MARK: - WhatsNewViewState

/// Encapsulates the loading lifecycle, concurrency generation tracking, and entry state
/// for ``WhatsNewView``.
struct WhatsNewViewState: Equatable, Sendable {
    /// The currently displayed changelog entries.
    var entries: [ChangelogEntry]

    /// Whether a changelog fetch is currently in flight.
    var isLoading: Bool

    /// True once a load has finished successfully or was permission-denied.
    /// Cancellation never marks this true, ensuring skeleton loaders display on reload.
    var hasLoadedOnce: Bool

    /// User-friendly error message if the most recent non-cancelled fetch failed.
    var loadError: String?

    /// Monotonically increasing generation counter to discard stale out-of-order responses.
    var loadGeneration: Int

    /// Creates a state with optional initial parameters.
    /// - Parameters:
    ///   - entries: Initial entries to display. Defaults to empty.
    ///   - isLoading: Whether a fetch is currently in flight. Defaults to true.
    ///   - hasLoadedOnce: Whether a load finished successfully or was denied. Defaults to false.
    ///   - loadError: Initial error message. Defaults to nil.
    ///   - loadGeneration: Initial load generation counter. Defaults to 0.
    init(
        entries: [ChangelogEntry] = [],
        isLoading: Bool = true,
        hasLoadedOnce: Bool = false,
        loadError: String? = nil,
        loadGeneration: Int = 0
    ) {
        self.entries = entries
        self.isLoading = isLoading
        self.hasLoadedOnce = hasLoadedOnce
        self.loadError = loadError
        self.loadGeneration = loadGeneration
    }

    /// Begins a load cycle, bumping the generation counter and setting loading state.
    /// - Returns: The generation ID for this load attempt.
    @discardableResult
    mutating func startLoading() -> Int {
        loadGeneration += 1
        isLoading = true
        loadError = nil
        return loadGeneration
    }

    /// Ends the load cycle for a specific generation.
    /// If a newer generation has started, `isLoading` remains unchanged.
    mutating func finishLoading(generation: Int) {
        if loadGeneration == generation {
            isLoading = false
        }
    }

    /// Handles successful receipt of changelog entries for a specific generation.
    mutating func handleSuccess(entries: [ChangelogEntry], generation: Int) {
        guard loadGeneration == generation else { return }
        self.entries = entries
        self.hasLoadedOnce = true
        self.loadError = nil
    }

    /// Handles a fetch failure for a specific generation.
    /// Cancellation errors are ignored to preserve existing state and avoid error banners.
    mutating func handleFailure(error: Error, generation: Int) {
        guard loadGeneration == generation, !error.isSdkCancellation else { return }
        self.loadError = FriendlyError.message(for: error)
    }

    /// Handles the case where changelog access is disallowed by console permissions.
    mutating func handlePermissionDenied() {
        self.isLoading = false
        self.hasLoadedOnce = true
    }
}
