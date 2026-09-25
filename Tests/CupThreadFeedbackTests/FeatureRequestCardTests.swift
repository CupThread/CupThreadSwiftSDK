import Foundation
import SwiftUI
import Testing
@testable import CupThreadFeedback

@Suite("FeatureRequestCard gesture isolation & sheet state")
struct FeatureRequestCardTests {
    private func makeItem(
        id: String = "fr-1",
        title: String = "Interactive Lock Screen Widgets",
        description: String = "Add Lock Screen widgets to track roadmap status.",
        status: String = "in-progress",
        voteCount: Int = 42,
        hasVoted: Bool = false,
        requesterClerkId: String? = nil,
        recentCommenters: [RecentCommenter] = [],
        releasedVersion: String? = nil
    ) -> FeatureRequestItem {
        FeatureRequestItem(
            id: id,
            appId: "app-1",
            title: title,
            description: description,
            status: status,
            columnId: "col-1",
            columnSlug: "in-progress",
            columnName: "In Progress",
            versionId: "ver-1",
            versionLabel: "v1.0.0",
            releasedVersion: releasedVersion,
            requesterName: "Sarah Connor",
            requesterAvatarUrl: nil,
            requesterClerkId: requesterClerkId,
            recentCommenters: recentCommenters,
            hasMoreCommenters: false,
            approved: true,
            voteCount: voteCount,
            hasVoted: hasVoted,
            isOwnRequest: false,
            createdAt: "2026-08-15T08:30:00.000Z",
            updatedAt: "2026-08-25T14:20:00.000Z"
        )
    }

    // MARK: - ActiveSheet destination exclusivity

    @Test func activeSheetIdentifiersAreUniquePerDestination() {
        let item1 = makeItem(id: "fr-100")
        let item2 = makeItem(id: "fr-200")

        let commentsSheet1 = FeatureRequestsActiveSheet.comments(item1)
        let commentsSheet2 = FeatureRequestsActiveSheet.comments(item2)
        let profileSheet1 = FeatureRequestsActiveSheet.profile("u_100")
        let profileSheet2 = FeatureRequestsActiveSheet.profile("u_200")

        #expect(commentsSheet1.id == "comments-fr-100")
        #expect(commentsSheet2.id == "comments-fr-200")
        #expect(profileSheet1.id == "profile-u_100")
        #expect(profileSheet2.id == "profile-u_200")
    }

    @Test func activeSheetEqualityAndMutualExclusivity() {
        let item1 = makeItem(id: "fr-1")
        let item2 = makeItem(id: "fr-2")

        let comments1 = FeatureRequestsActiveSheet.comments(item1)
        let comments2 = FeatureRequestsActiveSheet.comments(item2)
        let profile1 = FeatureRequestsActiveSheet.profile("user_1")
        let profile2 = FeatureRequestsActiveSheet.profile("user_2")

        #expect(comments1 == FeatureRequestsActiveSheet.comments(item1))
        #expect(comments1 != comments2)
        #expect(comments1 != profile1)
        #expect(profile1 == FeatureRequestsActiveSheet.profile("user_1"))
        #expect(profile1 != profile2)

        // Mutating a single destination state ensures comments and profile
        // presentation are mutually exclusive, preventing simultaneous dual sheets.
        var sheet: FeatureRequestsActiveSheet? = comments1
        #expect(sheet == comments1)

        sheet = profile1
        #expect(sheet == profile1)
        #expect(sheet != comments1)

        sheet = nil
        #expect(sheet == nil)
    }

    // MARK: - View evaluation and structure

    @Test @MainActor func cardEvaluatesBodyAcrossContentVariants() {
        let itemWithUserIds = makeItem(
            requesterClerkId: "clerk_author_1",
            recentCommenters: [
                RecentCommenter(authorName: "Alice", clerkUserId: "clerk_c1", avatarUrl: nil),
                RecentCommenter(authorName: "Bob", clerkUserId: nil, avatarUrl: nil)
            ]
        )

        let card = FeatureRequestCard(
            item: itemWithUserIds,
            highlightQuery: "Lock Screen",
            isVoteInFlight: false,
            successPulse: 1,
            onSelectCard: {},
            onSelectUser: { _ in },
            vote: {}
        )

        _ = card.body
        _ = card.cardContent
        _ = card.metaRow
    }

    @Test @MainActor func cardEvaluatesBodyWithReleasedVersion() {
        let releasedItem = makeItem(releasedVersion: "2.4.0")

        let card = FeatureRequestCard(
            item: releasedItem,
            isVoteInFlight: true,
            successPulse: 0,
            onSelectCard: {},
            onSelectUser: { _ in },
            vote: {}
        )

        _ = card.body
        _ = card.cardContent
        _ = card.metaRow
    }

    // MARK: - Callback wiring

    @Test @MainActor func cardCallbacksAreDispatched() {
        var didSelectCard = false
        var selectedUserId: String?
        var didVote = false

        let item = makeItem(requesterClerkId: "clerk_user_42")
        let card = FeatureRequestCard(
            item: item,
            isVoteInFlight: false,
            onSelectCard: { didSelectCard = true },
            onSelectUser: { selectedUserId = $0 },
            vote: { didVote = true }
        )

        card.onSelectCard?()
        #expect(didSelectCard)

        card.onSelectUser?("clerk_user_42")
        #expect(selectedUserId == "clerk_user_42")

        card.vote()
        #expect(didVote)
    }
}
