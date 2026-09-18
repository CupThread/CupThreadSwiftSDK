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
