import Foundation

// MARK: - Board model

/// Groups feature requests under their board column (by `columnId`).
/// Requests without a column or with an unlisted/hidden column land in a trailing "Other" group so nothing is dropped.
struct RoadmapGroup: Identifiable, Equatable, Sendable {
    let column: BoardColumn?
    let requests: [FeatureRequestItem]

    var id: String { column?.id ?? "uncategorized" }
    var name: String { column?.name ?? CupThreadStrings.tr("cupthread.roadmap.column_other") }
}

/// Groups feature requests under the visible board columns, preserving server ordering.
///
/// Feature requests without a column (`columnId == nil`) or whose column is not in the visible
/// `columns` list (e.g. internal, hidden, or deleted columns) are gathered into a trailing "Other"
/// group so no requests are dropped.
func makeGroups(columns: [BoardColumn], requests: [FeatureRequestItem]) -> [RoadmapGroup] {
    let listedIds = Set(columns.map(\.id))
    var byColumn = [String: [FeatureRequestItem]]()
    var uncategorized = [FeatureRequestItem]()
    for request in requests {
        if let columnId = request.columnId, listedIds.contains(columnId) {
            byColumn[columnId, default: []].append(request)
        } else {
            uncategorized.append(request)
        }
    }
    var groups = columns.map { column in
        RoadmapGroup(column: column, requests: byColumn[column.id] ?? [])
    }
    if !uncategorized.isEmpty {
        groups.append(RoadmapGroup(column: nil, requests: uncategorized))
    }
    return groups
}

// MARK: - Board load state

/// Loading lifecycle for ``RoadmapBoardView``: whether the first load
/// finished, the current full-screen error, and a monotonic generation
/// counter that discards stale out-of-order load writes (issue #274).
///
/// The generation matters because a load can be superseded two ways: by a
/// newer load (keystroke restart, pull-to-refresh) or by a permission
/// denial, which restarts the task without starting a load. Either way the
/// superseded run must not write results, errors, or notices — its writes
/// would land behind content (or the permission placeholder) that a newer
/// run now owns.
struct RoadmapBoardLoadState: Equatable, Sendable {
    /// Whether a board fetch is currently in flight.
    var isLoading: Bool
    /// True once the first load settled: finished (success or failure) or was
    /// permission-denied. A *cancelled* load never marks this true, so a
    /// superseded first load keeps the skeleton until the surviving run lands.
    var hasLoadedOnce: Bool
    /// User-friendly message when the latest failure had nothing to show.
    var loadError: String?
    /// Monotonically increasing counter; writes from a stale generation are
    /// discarded.
    var loadGeneration: Int

    init(
        isLoading: Bool = true,
        hasLoadedOnce: Bool = false,
        loadError: String? = nil,
        loadGeneration: Int = 0
    ) {
        self.isLoading = isLoading
        self.hasLoadedOnce = hasLoadedOnce
        self.loadError = loadError
        self.loadGeneration = loadGeneration
    }

    /// Starts a load cycle: bumps the generation, marks the board loading,
    /// and clears any previous full-screen error. Returns the generation to
    /// pass to ``finishLoading(generation:)`` and check with
    /// ``isCurrent(generation:)`` around every deferred write.
    @discardableResult
    mutating func startLoading() -> Int {
        loadGeneration += 1
        isLoading = true
        loadError = nil
        return loadGeneration
    }

    /// Ends the load cycle for `generation`. A superseded load leaves the
    /// flags alone — the newer load (or denial) owns them.
    ///
    /// A load whose task was cancelled, or whose generation a newer load has
    /// replaced, never reached a verdict: nothing is written, so the indicator
    /// and skeleton ownership stay with the load that is actually current.
    mutating func finishLoading(generation: Int, wasCancelled: Bool = false) {
        guard loadGeneration == generation, !wasCancelled else { return }
        isLoading = false
        hasLoadedOnce = true
    }

    /// Whether `generation` is still the current load cycle. Deferred writes
    /// (fetched groups, notices) must be gated on this so a superseded run
    /// cannot write behind newer content or the permission placeholder.
    func isCurrent(generation: Int) -> Bool {
        loadGeneration == generation
    }

    /// Records a full-screen load failure for `generation`; ignored when a
    /// newer load or a permission denial has superseded it.
    mutating func handleFailure(message: String, generation: Int) {
        guard loadGeneration == generation else { return }
        loadError = message
    }

    /// Settles the lifecycle for a permission denial (issue #274): the board
    /// is no longer first-loading, and the generation bump invalidates any
    /// in-flight permitted load so its success/failure writes cannot land
    /// behind the permission placeholder. With `groups` empty,
    /// `makeBoardDisplayState` renders `.emptyBoard` after this — but the
    /// permission placeholder replaces the board while denied, and a
    /// permitted flip restarts the load via the task key.
    mutating func settlePermissionDenied() {
        loadGeneration += 1
        isLoading = false
        hasLoadedOnce = true
        loadError = nil
    }
}

/// The `.task` identity for the roadmap board's load lifecycle (issue #274):
/// the permission verdict plus the trimmed search text. Keying on the search
/// text alone never re-ran the task when the config (or resolved
/// authentication) flipped the verdict, stranding the board on its
/// first-load skeleton; keying on the verdict alone would miss keystrokes.
/// A verdict-stable config refresh produces the same key and therefore no
/// restart.
func makeRoadmapLoadTaskKey(isRoadmapPermitted: Bool, trimmedSearchText: String) -> String {
    "\(isRoadmapPermitted)|\(trimmedSearchText)"
}

// MARK: - Board display state

/// The rendered state of the roadmap board, shared by all three layouts
/// (iPhone pager, regular-width scroll board, tvOS list) so identical inputs
/// render identical states everywhere.
enum RoadmapBoardDisplayState: Equatable, Sendable {
    /// The first load is still in flight.
    case loading
    /// A load failed and there is no previously rendered content to keep.
    case error(String)
    /// A search matched no requests in any column.
    case emptySearch(query: String)
    /// No roadmap columns have been published and no search is active.
    case emptyBoard
    /// Columns to render (already filtered to search matches while searching).
    case board([RoadmapGroup])
}

/// Derives the board's display state from the raw load inputs.
///
/// Pure on purpose: every layout must branch on this single derivation. The
/// regular-width and tvOS layouts used to test `groups.isEmpty` themselves and
/// fell through to an empty `ForEach` on zero-match searches, rendering a
/// blank board instead of the "No Results" placeholder.
///
/// Accepts either raw or trimmed search queries; whitespace-only strings are
/// treated as an empty query so unsearched empty columns are preserved.
func makeBoardDisplayState(
    isLoading: Bool,
    hasLoadedOnce: Bool,
    loadError: String?,
    searchText: String,
    groups: [RoadmapGroup]
) -> RoadmapBoardDisplayState {
    if isLoading && !hasLoadedOnce {
        return .loading
    }
    if let loadError {
        return .error(loadError)
    }
    let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let visibleGroups = trimmedQuery.isEmpty ? groups : groups.filter { !$0.requests.isEmpty }
    if visibleGroups.isEmpty {
        return trimmedQuery.isEmpty ? .emptyBoard : .emptySearch(query: trimmedQuery)
    }
    return .board(visibleGroups)
}
