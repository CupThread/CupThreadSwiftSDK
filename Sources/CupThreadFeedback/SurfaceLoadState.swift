import Foundation

// MARK: - Surface load state

/// Loading lifecycle shared by the SDK's simple single-fetch surfaces —
/// ``CommentsView`` and ``UserProfileView`` (CONC-4): the loading flag, the
/// latest full-screen error, a transient reload-failure notice, and a
/// monotonic generation counter that discards stale out-of-order writes.
///
/// A superseded load must not write behind newer data. A cancelled load
/// has no result to display, so it retains the loading presentation until
/// a replacement load settles or the surface disappears.
/// ``isCurrent(generation:)`` gates state writes, and
/// ``finishLoading(generation:wasCancelled:)`` settles only the current,
/// non-cancelled generation.
///
/// The state also carries the #59/#534 preserve-content invariant: a
/// reload failure must never wipe already-rendered content. Once a load
/// has settled successfully (``hasLoadedOnce``), a failure with content on
/// screen becomes the transient ``reloadNotice`` instead of the full-screen
/// error — the same decision shape as `SearchReloadOutcome` and
/// `WhatsNewViewState.handleFailure`.
struct SurfaceLoadState: Equatable, Sendable {
    /// Whether the surface is waiting for a resolved load outcome.
    var isLoading: Bool
    /// Whether any load has settled successfully. Once `true`, a reload
    /// failure with content on screen degrades to ``reloadNotice`` instead
    /// of replacing the rendered surface with the full-screen error (issue
    /// #545, preserving the #59/#534 contract).
    var hasLoadedOnce: Bool
    /// User-friendly message when the latest failure had nothing to show.
    var loadError: String?
    /// Transient notice for a failed reload whose content stays on screen
    /// (issue #545). Mutually exclusive with ``loadError`` within one
    /// verdict; cleared by the next ``startLoading()`` or successful load.
    var reloadNotice: String?
    /// Monotonically increasing counter; writes from a stale generation are
    /// discarded.
    var loadGeneration: Int

    /// Creates the lifecycle state.
    /// - Parameters:
    ///   - isLoading: Whether a fetch is currently in flight. Defaults to
    ///     `true` so a freshly presented surface renders its loading state
    ///     until the first `.task` load settles.
    ///   - hasLoadedOnce: Whether a load has already settled successfully.
    ///     Defaults to `false`.
    ///   - loadError: Initial error message. Defaults to `nil`.
    ///   - reloadNotice: Initial inline reload-failure notice. Defaults to
    ///     `nil`.
    ///   - loadGeneration: Initial generation counter. Defaults to `0`.
    init(
        isLoading: Bool = true,
        hasLoadedOnce: Bool = false,
        loadError: String? = nil,
        reloadNotice: String? = nil,
        loadGeneration: Int = 0
    ) {
        self.isLoading = isLoading
        self.hasLoadedOnce = hasLoadedOnce
        self.loadError = loadError
        self.reloadNotice = reloadNotice
        self.loadGeneration = loadGeneration
    }

    /// Starts a load cycle: bumps the generation, marks the surface loading,
    /// and clears any previous verdict — the full-screen error and the
    /// inline reload notice alike. Returns the generation to pass to
    /// ``finishLoading(generation:wasCancelled:)`` and check with
    /// ``isCurrent(generation:)`` around every write.
    @discardableResult
    mutating func startLoading() -> Int {
        loadGeneration += 1
        isLoading = true
        loadError = nil
        reloadNotice = nil
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

    /// Records a settled-successful load: pins ``hasLoadedOnce`` (the
    /// content-preservation marker, issue #545) and retires any inline
    /// reload notice. Gated on the generation so a superseded run cannot
    /// mark a newer run's surface.
    mutating func recordSuccess(generation: Int) {
        guard loadGeneration == generation else { return }
        hasLoadedOnce = true
        reloadNotice = nil
    }

    /// Settles a load failure under the #59/#534 preserve-content contract
    /// (issue #545): a failure with content on screen becomes the transient
    /// ``reloadNotice`` and leaves the rendered content untouched; a failure
    /// with nothing to show fills the surface via ``loadError``.
    /// Cancellation writes nothing — a cancelled load never reached a
    /// verdict. Mirrors `WhatsNewViewState.handleFailure` but maps messages
    /// through `FriendlyError.message(for:)`, so surface-specific rate-limit
    /// copy (search's) does not leak into these surfaces.
    /// - Parameter hasExistingContent: Whether the surface already renders
    ///   content the failure must preserve.
    mutating func handleFailure(
        error: Error,
        generation: Int,
        hasExistingContent: Bool
    ) {
        guard loadGeneration == generation, !error.isSdkCancellation else { return }
        let message = FriendlyError.message(for: error)
        if hasExistingContent {
            reloadNotice = message
            loadError = nil
        } else {
            loadError = message
            reloadNotice = nil
        }
    }
}
