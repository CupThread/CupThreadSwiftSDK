import Foundation

/// State container governing the feature request list, optimistic voting transitions,
/// and concurrent reload reconciliation.
public struct FeatureRequestsListState: Sendable, Equatable {
    /// The current items displayed in the list.
    public private(set) var items: [FeatureRequestItem]

    /// IDs of feature requests currently undergoing an in-flight vote request.
    public private(set) var votingIds: Set<String>

    /// Captured pre-vote state for in-flight votes.
    public struct InFlightVote: Sendable, Equatable {
        /// The identifier of the item being voted on.
        public let itemId: String
        /// The original vote status before the optimistic update.
        public let originalVoted: Bool
        /// The original vote count before the optimistic update.
        public let originalVoteCount: Int
        /// The optimistic vote status applied while the request is in flight.
        public let optimisticVoted: Bool
        /// The optimistic vote count applied while the request is in flight.
        public let optimisticVoteCount: Int

        /// Creates a new in-flight vote record.
        public init(
            itemId: String,
            originalVoted: Bool,
            originalVoteCount: Int,
            optimisticVoted: Bool,
            optimisticVoteCount: Int
        ) {
            self.itemId = itemId
            self.originalVoted = originalVoted
            self.originalVoteCount = originalVoteCount
            self.optimisticVoted = optimisticVoted
            self.optimisticVoteCount = optimisticVoteCount
        }
    }

    /// Internal storage mapping item IDs to their active in-flight vote records.
    private var inFlightVotes: [String: InFlightVote]

    /// Creates a new state container with the given items.
    /// - Parameter items: Initial list of feature request items.
    public init(items: [FeatureRequestItem] = []) {
        self.items = items
        self.votingIds = []
        self.inFlightVotes = [:]
    }

    /// Returns whether a vote request is currently in flight for the given item ID.
    /// - Parameter id: The feature request item ID.
    /// - Returns: `true` if a vote request is in flight; otherwise `false`.
    public func isVoting(for id: String) -> Bool {
        votingIds.contains(id)
    }

    /// Returns the active in-flight vote for the given item ID, if any.
    /// - Parameter id: The feature request item ID.
    /// - Returns: The `InFlightVote` record if active, otherwise `nil`.
    public func inFlightVote(for id: String) -> InFlightVote? {
        inFlightVotes[id]
    }

    /// Begins an optimistic vote on the specified item.
    ///
    /// Applies the optimistic vote state immediately to the item in `items`,
    /// tracks the ID in `votingIds`, and records the pre-vote state.
    ///
    /// - Parameter item: The item to vote on.
    /// - Returns: The recorded `InFlightVote` if the vote was started, or `nil` if a vote
    ///   is already in flight for this ID or if the item is not found.
    @discardableResult
    public mutating func startVote(for item: FeatureRequestItem) -> InFlightVote? {
        guard !votingIds.contains(item.id),
              let index = items.firstIndex(where: { $0.id == item.id }) else {
            return nil
        }

        let currentItem = items[index]
        let newVoted = !currentItem.hasVoted
        let newCount = currentItem.hasVoted ? max(0, currentItem.voteCount - 1) : currentItem.voteCount + 1

        let vote = InFlightVote(
            itemId: item.id,
            originalVoted: currentItem.hasVoted,
            originalVoteCount: currentItem.voteCount,
            optimisticVoted: newVoted,
            optimisticVoteCount: newCount
        )

        votingIds.insert(item.id)
        inFlightVotes[item.id] = vote
        items[index] = currentItem.withVoteState(voted: newVoted, count: newCount)

        return vote
    }

    /// Reconciles an authoritative vote response from the server.
    ///
    /// Updates the row's vote state with the server's authoritative values by ID,
    /// regardless of whether the row index shifted or the list was reloaded.
    /// Clears the in-flight vote status.
    ///
    /// - Parameters:
    ///   - itemId: The ID of the item that was voted on.
    ///   - voted: Authoritative vote state returned by the server.
    ///   - voteCount: Authoritative vote count returned by the server.
    /// - Returns: `true` if the item was found and updated, or `false` otherwise.
    @discardableResult
    public mutating func voteSucceeded(itemId: String, voted: Bool, voteCount: Int) -> Bool {
        votingIds.remove(itemId)
        inFlightVotes.removeValue(forKey: itemId)

        if let index = items.firstIndex(where: { $0.id == itemId }) {
            items[index] = items[index].withVoteState(voted: voted, count: voteCount)
            return true
        }
        return false
    }

    /// Reverts an optimistic vote after a network failure or server error.
    ///
    /// Reverts **only** the `hasVoted` and `voteCount` fields back to their pre-optimistic
    /// values on the **current** row, preserving any fresh metadata (such as updated
    /// titles, descriptions, comments, or status) that arrived via a concurrent list reload.
    ///
    /// - Parameter itemId: The ID of the item whose vote failed.
    /// - Returns: `true` if the item was found and reverted, or `false` otherwise.
    @discardableResult
    public mutating func voteFailed(itemId: String) -> Bool {
        votingIds.remove(itemId)
        guard let inFlight = inFlightVotes.removeValue(forKey: itemId) else {
            return false
        }

        if let index = items.firstIndex(where: { $0.id == itemId }) {
            items[index] = items[index].withVoteState(
                voted: inFlight.originalVoted,
                count: inFlight.originalVoteCount
            )
            return true
        }
        return false
    }

    /// Merges freshly fetched items from a server reload, preserving in-flight
    /// optimistic vote states so concurrent reloads do not cause visible vote flickers.
    ///
    /// - Parameter reloadedItems: The items returned from the server.
    public mutating func reloadItems(_ reloadedItems: [FeatureRequestItem]) {
        guard !votingIds.isEmpty else {
            items = reloadedItems
            return
        }

        // Merge incoming rows with active in-flight optimistic votes.
        items = reloadedItems.map { reloaded in
            if let inFlight = inFlightVotes[reloaded.id] {
                return reloaded.withVoteState(
                    voted: inFlight.optimisticVoted,
                    count: inFlight.optimisticVoteCount
                )
            }
            return reloaded
        }
    }
}
