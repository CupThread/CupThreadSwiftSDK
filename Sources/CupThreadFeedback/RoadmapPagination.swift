import Foundation
import os

let paginationLogger = Logger(subsystem: "com.cupthread.sdk", category: "pagination")

// MARK: - Complete-data pagination (roadmap board)

/// Default configuration values for complete-data roadmap pagination.
public enum RoadmapPaginationDefaults {
    /// The default maximum number of cursor pages to fetch before gracefully stopping (100).
    public static let defaultMaxPages = FeedbackClient.defaultMaxPages
}

/// Fetches every page of feature requests matching a filter, for surfaces
/// that must render complete data.
///
/// The roadmap board groups requests under columns, so a single page silently
/// truncates the board once an app outgrows the server's page size — columns
/// would show partial groups and counts. This walks the server's keyset
/// cursor until the result set is complete:
///
/// - Stops when a page reports ``ListFeatureRequestsResult/hasMore`` is `false`
///   or no ``ListFeatureRequestsResult/nextCursor``.
/// - Stops once the collected count reaches the page's unpaginated
///   ``ListFeatureRequestsResult/total`` (ignored when the server omits it,
///   which decodes as `0`).
/// - Stops when a page yields no IDs that were not already collected, so a
///   misbehaving backend that keeps replaying the same cursor cannot hang
///   the board.
/// - Stops when reaching `maxPages` (defaults to ``RoadmapPaginationDefaults/defaultMaxPages``,
///   100) to protect against infinite loops from runaway backends or shifting keyset cursors.
///   When the cap is reached, collected results are returned and a warning diagnostic is logged.
///
/// Throws on the first failed page so the caller applies its normal
/// reload-failure presentation.
/// - Parameters:
///   - appKey: Optional CupThread app key used for logging diagnostics when the cap is reached.
///   - maxPages: Maximum number of cursor pages to fetch before stopping;
///     defaults to ``RoadmapPaginationDefaults/defaultMaxPages`` (100).
///   - fetchPage: Closure fetching a single page for a cursor.
/// - Returns: All collected feature requests.
func collectAllRequests(
    appKey: String? = nil,
    maxPages: Int = RoadmapPaginationDefaults.defaultMaxPages,
    fetchPage: @Sendable (_ cursor: String?) async throws -> ListFeatureRequestsResult
) async throws -> [FeatureRequestItem] {
    let effectiveMaxPages = max(1, maxPages)
    var collected: [FeatureRequestItem] = []
    var seenIDs = Set<String>()
    var cursor: String?
    var pagesFetched = 0
    while pagesFetched < effectiveMaxPages {
        pagesFetched += 1
        let page = try await fetchPage(cursor)
        let freshItems = page.requests.filter { seenIDs.insert($0.id).inserted }
        collected.append(contentsOf: freshItems)
        let reachedTotal = page.total > 0 && collected.count >= page.total
        guard page.hasMore, let nextCursor = page.nextCursor, !freshItems.isEmpty, !reachedTotal else {
            return collected
        }
        cursor = nextCursor
    }
    paginationLogger.warning(
        "Roadmap pagination reached maximum page cap (\(effectiveMaxPages, privacy: .public)) for app '\(appKey ?? "unknown", privacy: .public)'; returning \(collected.count, privacy: .public) collected requests."
    )
    return collected
}
