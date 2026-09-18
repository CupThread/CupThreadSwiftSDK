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
    let visibleGroups = searchText.isEmpty ? groups : groups.filter { !$0.requests.isEmpty }
    if visibleGroups.isEmpty {
        return searchText.isEmpty ? .emptyBoard : .emptySearch(query: searchText)
    }
    return .board(visibleGroups)
}
