import Foundation

// MARK: - Complete-data pagination (roadmap board)

/// Fetches every page of feature requests matching a filter, for surfaces
/// that must render complete data.
///
/// The roadmap board groups requests under columns, so a single page silently
/// truncates the board once an app outgrows the server's page size — columns
/// would show partial groups and counts. This walks the server's keyset
/// cursor until the result set is complete:
///
/// - Stops when a page reports no ``ListFeatureRequestsResult/nextCursor``.
/// - Stops once the collected count reaches the page's unpaginated
///   ``ListFeatureRequestsResult/total`` (ignored when the server omits it,
///   which decodes as `0`).
/// - Stops when a page yields no IDs that were not already collected, so a
///   misbehaving backend that keeps replaying the same cursor cannot hang
///   the board.
///
/// Throws on the first failed page so the caller applies its normal
/// reload-failure presentation.
func collectAllRequests(
    fetchPage: @Sendable (_ cursor: String?) async throws -> ListFeatureRequestsResult
) async throws -> [FeatureRequestItem] {
    var collected: [FeatureRequestItem] = []
    var seenIDs = Set<String>()
    var cursor: String?
    while true {
        let page = try await fetchPage(cursor)
        let freshItems = page.requests.filter { seenIDs.insert($0.id).inserted }
        collected.append(contentsOf: freshItems)
        let reachedTotal = page.total > 0 && collected.count >= page.total
        guard let nextCursor = page.nextCursor, !freshItems.isEmpty, !reachedTotal else {
            return collected
        }
        cursor = nextCursor
    }
}
