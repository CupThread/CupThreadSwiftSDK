import Foundation

// MARK: - FeatureRequestsListState

/// Manages the in-memory list of feature requests, in-flight optimistic vote state,
/// and race-free reconciliation across asynchronous reloads and vote results.
struct FeatureRequestsListState: Equatable, Sendable {
    /// The current items displayed in the list.
    var items: [FeatureRequestItem]

    /// Tracks which item IDs have an in-flight vote request (prevents double-taps).
    var votingIds: Set<String>

    /// Opaque keyset cursor for the next page, from the most recent fetch.
    /// `nil` when the last fetch reported no further pages (or used offsets).
    var nextCursor: String?

    /// Whether the most recent fetch reported another page. Offset-based
    /// fetches never report it, so this stays `false` until a cursor page
    /// comes back.
    var hasMorePages: Bool

    /// Creates a list state with optional initial items and in-flight voting IDs.
    /// - Parameters:
    ///   - items: Initial items in the list.
    ///   - votingIds: Initial item IDs with in-flight vote requests.
    init(items: [FeatureRequestItem] = [], votingIds: Set<String> = []) {
        self.items = items
        self.votingIds = votingIds
        self.nextCursor = nil
        self.hasMorePages = false
    }

    /// Applies a fetched page to the list.
    ///
    /// A replacing page (first load, search, filter, pull-to-refresh) swaps
    /// the items for the fresh ones while preserving in-flight optimistic
    /// votes; an appending page (cursor pagination) adds only items not
    /// already shown, so overlapping pages never duplicate rows.
    ///
    /// - Parameters:
    ///   - result: The fetched page, including `hasMore`/`nextCursor`.
    ///   - replacesExisting: `true` for a fresh load, `false` to append.
    mutating func applyPage(_ result: ListFeatureRequestsResult, replacesExisting: Bool) {
        nextCursor = result.nextCursor
        hasMorePages = result.hasMore && result.nextCursor != nil
        if replacesExisting {
            mergeReloadedItems(result.requests)
        } else {
            let knownIDs = Set(items.map(\.id))
            items.append(contentsOf: result.requests.filter { !knownIDs.contains($0.id) })
        }
    }

    /// Attempts to apply an optimistic vote for the specified item.
    ///
    /// If an in-flight vote already exists for this item or if the item is not found,
    /// this method returns `nil` and performs no mutation.
    ///
    /// Otherwise, `votingIds` is updated and the item's `hasVoted` and `voteCount`
    /// are toggled optimistically.
    ///
    /// - Parameter itemId: The ID of the item to toggle vote for.
    /// - Returns: A tuple containing the pre-vote `(originalVoted, originalCount)` state if applied, or `nil`.
    mutating func applyOptimisticVote(for itemId: String) -> (originalVoted: Bool, originalCount: Int)? {
        guard !votingIds.contains(itemId),
              let index = items.firstIndex(where: { $0.id == itemId }) else {
            return nil
        }

        let current = items[index]
        let originalVoted = current.hasVoted
        let originalCount = current.voteCount

        votingIds.insert(itemId)
        items[index] = current.withVoteState(
            voted: !originalVoted,
            count: originalVoted ? originalCount - 1 : originalCount + 1
        )

        return (originalVoted, originalCount)
    }

    /// Reconciles an authoritative vote result from the server.
    ///
    /// Clears the in-flight voting state for `itemId` and updates the item's
    /// vote fields while preserving any newer server fields.
    ///
    /// - Parameters:
    ///   - itemId: The ID of the item that was voted on.
    ///   - voted: Authoritative vote status from the server.
    ///   - voteCount: Authoritative vote count from the server.
    mutating func reconcileVoteSuccess(itemId: String, voted: Bool, voteCount: Int) {
        votingIds.remove(itemId)
        if let idx = items.firstIndex(where: { $0.id == itemId }) {
            items[idx] = items[idx].withVoteState(voted: voted, count: voteCount)
        }
    }

    /// Reconciles a failed vote request by reverting only the vote fields.
    ///
    /// Clears the in-flight voting state for `itemId` and restores `hasVoted`
    /// and `voteCount` on the current row. Any surrounding fields (title,
    /// description, status, comments, etc.) loaded from concurrent server
    /// refreshes are preserved.
    ///
    /// - Parameters:
    ///   - itemId: The ID of the item whose vote failed.
    ///   - originalVoted: The pre-vote `hasVoted` state to restore.
    ///   - originalCount: The pre-vote `voteCount` to restore.
    mutating func reconcileVoteFailure(itemId: String, originalVoted: Bool, originalCount: Int) {
        votingIds.remove(itemId)
        if let idx = items.firstIndex(where: { $0.id == itemId }) {
            items[idx] = items[idx].withVoteState(voted: originalVoted, count: originalCount)
        }
    }

    /// Merges freshly loaded server items into the list.
    ///
    /// If an item currently has an in-flight optimistic vote (`votingIds.contains(newItem.id)`),
    /// the fresh server metadata (title, comments, status, etc.) is accepted, but the
    /// in-flight optimistic vote state is preserved so the UI does not flicker or prematurely
    /// roll back before the server request completes.
    ///
    /// - Parameter reloadedItems: The items returned from the server.
    mutating func mergeReloadedItems(_ reloadedItems: [FeatureRequestItem]) {
        items = reloadedItems.map { newItem in
            if votingIds.contains(newItem.id),
               let current = items.first(where: { $0.id == newItem.id }) {
                return newItem.withVoteState(voted: current.hasVoted, count: current.voteCount)
            }
            return newItem
        }
    }
}

// MARK: - Vote failure presentation

/// How a failed optimistic vote should be presented to the user.
///
/// A reverted vote used to fail silently — the pill flipped and flipped back
/// with no explanation, so users on flaky connections believed they had voted
/// when they had not, and rate-limited users had no idea why voting stopped
/// working. Every real failure now maps to a transient notice; only
/// cancellation stays silent, because a cancelled vote means the surface went
/// away rather than that something failed.
///
/// The view mutates its state synchronously around the vote's `await` (an
/// async mutating call would hold exclusive access across the network
/// round-trip), so classification — not orchestration — is what lives here.
enum VoteFailureNotice: Equatable {
    /// Task cancellation (surface dismissed / superseded) — present nothing.
    case silent
    /// HTTP 429: the vote endpoint's per-client-IP budget was hit.
    case rateLimited
    /// Console permission rejected the vote (anonymous voting disabled).
    case permissionDenied
    /// Any other failure (offline, 5xx): generic copy.
    case generic

    /// Maps a thrown vote error to its presentation.
    static func notice(for error: Error) -> VoteFailureNotice {
        if error is CancellationError { return .silent }
        if let urlError = error as? URLError, urlError.code == .cancelled { return .silent }
        if let clientError = error as? FeedbackClientError {
            switch clientError {
            case .rateLimited:
                return .rateLimited
            case .authenticationRequired, .forbidden:
                return .permissionDenied
            default:
                break
            }
        }
        return .generic
    }

    /// The transient banner copy for this failure (empty for `.silent`).
    var message: String {
        switch self {
        case .silent:
            return ""
        case .rateLimited:
            return CupThreadStrings.tr("cupthread.features.vote_rate_limited")
        case .permissionDenied:
            return CupThreadStrings.tr("cupthread.error.forbidden")
        case .generic:
            return CupThreadStrings.tr("cupthread.features.vote_failed")
        }
    }
}
