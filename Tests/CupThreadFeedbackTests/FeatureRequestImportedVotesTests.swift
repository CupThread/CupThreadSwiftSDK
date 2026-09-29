import Foundation
import Testing
@testable import CupThreadFeedback

@Suite("FeatureRequestImportedVotes", .serialized)
struct FeatureRequestImportedVotesTests {
    static let apiHost = "imported-votes.example.com"

    static func makeAPIClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(apiHost)")!)
    }

    private static func makeItemJSON(
        voteCount: Int = 124,
        importedVotes: Int? = 120
    ) -> [String: Any] {
        var json: [String: Any] = [
            "id": "fr-import-1",
            "appId": "app-test-1",
            "title": "Imported feature idea",
            "description": "Historical issue from GitHub",
            "status": "planned",
            "approved": true,
            "voteCount": voteCount,
            "hasVoted": false,
            "isOwnRequest": false,
            "createdAt": "2026-09-01T00:00:00.000Z",
            "updatedAt": "2026-09-20T00:00:00.000Z"
        ]
        if let importedVotes {
            json["importedVotes"] = importedVotes
        }
        return json
    }

    @Test func featureRequestItemDecodesImportedVotesAndSummedVoteCount() throws {
        // CupThread SaaS PR #395 / Issue #225:
        // A request imported from GitHub with 120 reactions and 4 votes in CupThread
        // returns voteCount: 124, importedVotes: 120.
        let json = try encodeJSON(Self.makeItemJSON(voteCount: 124, importedVotes: 120))
        let item = try JSONDecoder().decode(FeatureRequestItem.self, from: json)

        #expect(item.voteCount == 124)
        #expect(item.importedVotes == 120)
    }

    @Test func featureRequestItemDecodesZeroImportedVotesForNativeRequests() throws {
        // Requests created directly in CupThread return importedVotes: 0.
        let json = try encodeJSON(Self.makeItemJSON(voteCount: 5, importedVotes: 0))
        let item = try JSONDecoder().decode(FeatureRequestItem.self, from: json)

        #expect(item.voteCount == 5)
        #expect(item.importedVotes == 0)
    }

    @Test func featureRequestItemDecodesOmittedImportedVotesAsNil() throws {
        // Older backend deployments or payloads omitting importedVotes decode to nil.
        let json = try encodeJSON(Self.makeItemJSON(voteCount: 7, importedVotes: nil))
        let item = try JSONDecoder().decode(FeatureRequestItem.self, from: json)

        #expect(item.voteCount == 7)
        #expect(item.importedVotes == nil)
    }

    @Test func featureRequestItemPreservesImportedVotesAcrossWithVoteState() throws {
        let base = FeatureRequestItem(
            id: "fr-import-1",
            appId: "app-test-1",
            title: "Imported request",
            description: "From Linear",
            status: "in-progress",
            approved: true,
            voteCount: 124,
            importedVotes: 120,
            hasVoted: false,
            isOwnRequest: false,
            createdAt: "2026-09-01T00:00:00.000Z",
            updatedAt: "2026-09-20T00:00:00.000Z"
        )

        let upvoted = base.withVoteState(voted: true, count: 125)
        #expect(upvoted.voteCount == 125)
        #expect(upvoted.hasVoted == true)
        #expect(upvoted.importedVotes == 120)

        let revoked = upvoted.withVoteState(voted: false, count: 124)
        #expect(revoked.voteCount == 124)
        #expect(revoked.hasVoted == false)
        #expect(revoked.importedVotes == 120)
    }

    @Test func featureRequestItemCodableRoundTripPreservesImportedVotes() throws {
        let original = FeatureRequestItem(
            id: "fr-roundtrip-1",
            appId: "app-test-1",
            title: "Roundtrip item",
            description: "Tests Codable round-trip",
            status: "under-review",
            columnId: "col-1",
            columnSlug: "under-review",
            columnName: "Under Review",
            versionId: "ver-1",
            versionLabel: "1.0",
            releasedVersion: nil,
            requesterName: "Developer",
            requesterAvatarUrl: "https://example.com/avatar.png",
            requesterClerkId: "u_abc123",
            recentCommenters: [],
            hasMoreCommenters: false,
            approved: true,
            voteCount: 124,
            importedVotes: 120,
            hasVoted: true,
            isOwnRequest: false,
            createdAt: "2026-09-01T00:00:00.000Z",
            updatedAt: "2026-09-20T00:00:00.000Z"
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FeatureRequestItem.self, from: encoded)

        #expect(decoded == original)
        #expect(decoded.importedVotes == 120)
        #expect(decoded.voteCount == 124)
    }

    @Test func voteResultDecodesImportedVotesWhenPresent() throws {
        let json = Data("""
        {"hasVoted": true, "voteCount": 124, "importedVotes": 120}
        """.utf8)

        let result = try JSONDecoder().decode(VoteResult.self, from: json)
        #expect(result.voted == true)
        #expect(result.voteCount == 124)
        #expect(result.importedVotes == 120)
    }

    @Test func voteResultDecodesOmittedImportedVotesAsNil() throws {
        let json = Data("""
        {"voted": true, "voteCount": 12}
        """.utf8)

        let result = try JSONDecoder().decode(VoteResult.self, from: json)
        #expect(result.voted == true)
        #expect(result.voteCount == 12)
        #expect(result.importedVotes == nil)
    }

    @Test func toggleVoteEndpointDecodesVoteResultWithImportedVotes() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            let json: [String: Any] = [
                "voted": true,
                "voteCount": 124,
                "importedVotes": 120
            ]
            return (makeHTTPResponse(status: 200), try encodeJSON(json))
        }

        let result = try await Self.makeAPIClient().toggleVote(
            featureRequestId: "fr-import-1",
            userToken: "test-token"
        )

        #expect(result.voted == true)
        #expect(result.voteCount == 124)
        #expect(result.importedVotes == 120)
    }

    @Test func listStateVoteReconciliationPreservesImportedVotes() {
        let initialItem = FeatureRequestItem(
            id: "fr-state-1",
            appId: "app-test-1",
            title: "List state item",
            description: "Testing state reconciliation",
            status: "planned",
            approved: true,
            voteCount: 124,
            importedVotes: 120,
            hasVoted: false,
            isOwnRequest: false,
            createdAt: "2026-09-01T00:00:00.000Z",
            updatedAt: "2026-09-20T00:00:00.000Z"
        )

        var state = FeatureRequestsListState(items: [initialItem])
        _ = state.applyOptimisticVote(for: initialItem.id)
        #expect(state.items[0].voteCount == 125)
        #expect(state.items[0].hasVoted == true)
        #expect(state.items[0].importedVotes == 120)

        // Server responds with authoritative count:
        state.reconcileVoteSuccess(itemId: initialItem.id, voted: true, voteCount: 125)
        #expect(state.items[0].voteCount == 125)
        #expect(state.items[0].hasVoted == true)
        #expect(state.items[0].importedVotes == 120)
    }
}
