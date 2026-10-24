import Foundation

// MARK: - WhatsNewViewState

/// Encapsulates the loading lifecycle, concurrency generation tracking, and entry state
/// for ``WhatsNewView``.
struct WhatsNewViewState: Equatable, Sendable {
    /// The currently displayed changelog entries.
    var entries: [ChangelogEntry]

    /// Whether to show loading, including a cancelled load awaiting a replacement.
    var isLoading: Bool

    /// True once a load has finished successfully or was permission-denied.
    /// Cancellation never marks this true, ensuring skeleton loaders display on reload.
    var hasLoadedOnce: Bool

    /// User-friendly error message if the most recent non-cancelled fetch failed
    /// with nothing rendered yet: the full-screen error view owns the surface.
    var loadError: String?

    /// Transient notice for a failed refresh whose entries stay on screen
    /// (a reload failure never wipes already-rendered content — issue #534).
    /// Mutually exclusive with ``loadError`` within one verdict.
    var reloadNotice: String?

    /// Monotonically increasing generation counter to discard stale out-of-order responses.
    var loadGeneration: Int

    /// Creates a state with optional initial parameters.
    /// - Parameters:
    ///   - entries: Initial entries to display. Defaults to empty.
    ///   - isLoading: Whether a fetch is currently in flight. Defaults to true.
    ///   - hasLoadedOnce: Whether a load finished successfully or was denied. Defaults to false.
    ///   - loadError: Initial full-screen error message. Defaults to nil.
    ///   - reloadNotice: Initial inline reload notice. Defaults to nil.
    ///   - loadGeneration: Initial load generation counter. Defaults to 0.
    init(
        entries: [ChangelogEntry] = [],
        isLoading: Bool = true,
        hasLoadedOnce: Bool = false,
        loadError: String? = nil,
        reloadNotice: String? = nil,
        loadGeneration: Int = 0
    ) {
        self.entries = entries
        self.isLoading = isLoading
        self.hasLoadedOnce = hasLoadedOnce
        self.loadError = loadError
        self.reloadNotice = reloadNotice
        self.loadGeneration = loadGeneration
    }

    /// Begins a load cycle, bumping the generation counter and setting loading state.
    /// - Returns: The generation ID for this load attempt.
    @discardableResult
    mutating func startLoading() -> Int {
        loadGeneration += 1
        isLoading = true
        loadError = nil
        reloadNotice = nil
        return loadGeneration
    }

    /// Ends the load cycle for a specific generation.
    /// Cancelled loads have no verdict; they and stale generations preserve the presentation.
    mutating func finishLoading(generation: Int, wasCancelled: Bool = false) {
        if loadGeneration == generation, !wasCancelled {
            isLoading = false
        }
    }

    /// Handles successful receipt of changelog entries for a specific generation.
    mutating func handleSuccess(entries: [ChangelogEntry], generation: Int) {
        guard loadGeneration == generation else { return }
        self.entries = entries
        self.hasLoadedOnce = true
        self.loadError = nil
        self.reloadNotice = nil
    }

    /// Handles a fetch failure for a specific generation.
    ///
    /// Reuses ``SearchReloadOutcome`` so the changelog surface shares the
    /// #59/#534 invariant with the list and board: a failure with entries on
    /// screen becomes a transient notice and preserves them, while a failure
    /// with nothing to show fills the surface with the full-screen error.
    /// Cancellation errors are ignored to preserve existing state and avoid
    /// error banners.
    mutating func handleFailure(error: Error, generation: Int) {
        guard loadGeneration == generation else { return }
        guard let outcome = SearchReloadOutcome.outcome(
            for: error,
            hasExistingContent: hasLoadedOnce && !entries.isEmpty
        ) else { return }
        switch outcome {
        case .inlineNotice(let message):
            reloadNotice = message
            loadError = nil
        case .fullScreenError(let message):
            loadError = message
            reloadNotice = nil
        }
    }

    /// Handles the case where changelog access is disallowed by console permissions for a specific generation.
    /// Invalidates stale in-flight loads by bumping the generation counter.
    mutating func handlePermissionDenied(generation: Int) {
        guard loadGeneration == generation else { return }
        self.isLoading = false
        self.hasLoadedOnce = true
        self.loadError = nil
        self.reloadNotice = nil
        self.loadGeneration += 1
    }

    /// Handles the case where changelog access is disallowed by console permissions.
    mutating func handlePermissionDenied() {
        handlePermissionDenied(generation: loadGeneration)
    }
}

// MARK: - Load task key (issues #265, #364)

/// The `.task` identity for ``WhatsNewView``'s load lifecycle (issues #265,
/// #364): the config's `allowsAnonymousChangelog` switch. Keying on the
/// *resolved permission verdict* made the task cancel and restart itself,
/// because the task's first act — resolving authentication — flipped the
/// verdict and with it the key mid-flight. The switch is external to the task
/// (the task cannot mutate it), so a locked-down changelog resolves
/// authentication inside one stable-key run; a switch-stable config refresh
/// produces the same key and therefore no restart.
func makeChangelogLoadTaskKey(allowsAnonymousChangelog: Bool) -> Bool {
    allowsAnonymousChangelog
}
