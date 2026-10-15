import Foundation
import Testing
@testable import CupThreadFeedback

@Suite("Sorting Determinism Tests", .serialized)
struct SortingDeterminismTests {
    static let apiHost = "sorting.example.com"

    static func makeSortingClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(apiHost)")!)
    }

    // MARK: - Columns

    @Test("Columns with identical positions sort deterministically by id")
    func testFetchColumnsWithIdenticalPositionsSortsById() async throws {
        let capture = CaptureBox<URL>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request.url
            let columns = [
                makeColumnJSON(id: "col-c", position: 0),
                makeColumnJSON(id: "col-a", position: 0),
                makeColumnJSON(id: "col-b", position: 0),
                makeColumnJSON(id: "col-z", position: 1)
            ]
            return (makeHTTPResponse(), try encodeJSON(["columns": columns]))
        }

        let columns = try await Self.makeSortingClient().fetchColumns()
        #expect(columns.map(\.id) == ["col-a", "col-b", "col-c", "col-z"])
    }

    @Test("Columns sorting is invariant to input order")
    func testColumnsSortingInvariance() async throws {
        let permutations: [[[String: Any]]] = [
            [
                makeColumnJSON(id: "col-b", position: 0),
                makeColumnJSON(id: "col-a", position: 0)
            ],
            [
                makeColumnJSON(id: "col-a", position: 0),
                makeColumnJSON(id: "col-b", position: 0)
            ]
        ]

        for input in permutations {
            MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
                (makeHTTPResponse(), try encodeJSON(["columns": input]))
            }
            let columns = try await Self.makeSortingClient().fetchColumns()
            #expect(columns.map(\.id) == ["col-a", "col-b"])
        }
    }

    // MARK: - Versions

    @Test("Versions with identical positions sort deterministically by id")
    func testFetchVersionsWithIdenticalPositionsSortsById() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            let versions = [
                makeVersionJSON(id: "ver-c", position: 0),
                makeVersionJSON(id: "ver-a", position: 0),
                makeVersionJSON(id: "ver-b", position: 0),
                makeVersionJSON(id: "ver-z", position: 2)
            ]
            return (makeHTTPResponse(), try encodeJSON(["versions": versions]))
        }

        let versions = try await Self.makeSortingClient().fetchVersions()
        #expect(versions.map(\.id) == ["ver-a", "ver-b", "ver-c", "ver-z"])
    }

    @Test("Versions sorting is invariant to input order")
    func testVersionsSortingInvariance() async throws {
        let permutations: [[[String: Any]]] = [
            [
                makeVersionJSON(id: "ver-2", position: 1),
                makeVersionJSON(id: "ver-1", position: 1)
            ],
            [
                makeVersionJSON(id: "ver-1", position: 1),
                makeVersionJSON(id: "ver-2", position: 1)
            ]
        ]

        for input in permutations {
            MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
                (makeHTTPResponse(), try encodeJSON(["versions": input]))
            }
            let versions = try await Self.makeSortingClient().fetchVersions()
            #expect(versions.map(\.id) == ["ver-1", "ver-2"])
        }
    }

    // MARK: - Changelog Entries

    @Test("Changelog entries with identical dates sort deterministically by id descending")
    func testFetchChangelogWithIdenticalDatesSortsByIdDescending() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            let entries = [
                makeEntryJSON(id: "e-alpha", publishedAt: "2026-02-01T00:00:00Z"),
                makeEntryJSON(id: "e-gamma", publishedAt: "2026-02-01T00:00:00Z"),
                makeEntryJSON(id: "e-beta", publishedAt: "2026-02-01T00:00:00Z"),
                makeEntryJSON(id: "e-older", publishedAt: "2025-12-01T00:00:00Z")
            ]
            return (makeHTTPResponse(), try encodeJSON(["entries": entries]))
        }

        let entries = try await Self.makeSortingClient().fetchChangelog()
        #expect(entries.map(\.id) == ["e-gamma", "e-beta", "e-alpha", "e-older"])
    }

    @Test("sortChangelogEntries deterministically breaks date ties across permutations")
    func testSortChangelogEntriesDeterminism() {
        let entryA = ChangelogEntry(
            id: "entry-a",
            title: "A",
            body: "Body A",
            versionLabel: "1.0",
            publishedAt: "2026-01-01T00:00:00Z",
            linkedRequests: []
        )
        let entryB = ChangelogEntry(
            id: "entry-b",
            title: "B",
            body: "Body B",
            versionLabel: "1.0",
            publishedAt: "2026-01-01T00:00:00Z",
            linkedRequests: []
        )
        let entryC = ChangelogEntry(
            id: "entry-c",
            title: "C",
            body: "Body C",
            versionLabel: "1.0",
            publishedAt: "2026-01-01T00:00:00Z",
            linkedRequests: []
        )

        let expectedIDs = ["entry-c", "entry-b", "entry-a"]
        #expect(FeedbackClient.sortChangelogEntries([entryA, entryB, entryC]).map(\.id) == expectedIDs)
        #expect(FeedbackClient.sortChangelogEntries([entryC, entryA, entryB]).map(\.id) == expectedIDs)
        #expect(FeedbackClient.sortChangelogEntries([entryB, entryC, entryA]).map(\.id) == expectedIDs)
        #expect(FeedbackClient.sortChangelogEntries([entryA, entryC, entryB]).map(\.id) == expectedIDs)
    }

    @Test("sortChangelogEntries deterministically breaks invalid date ties")
    func testSortChangelogEntriesInvalidDates() {
        let entryA = ChangelogEntry(
            id: "entry-a",
            title: "A",
            body: "Body A",
            versionLabel: nil,
            publishedAt: "not-a-valid-date",
            linkedRequests: []
        )
        let entryB = ChangelogEntry(
            id: "entry-b",
            title: "B",
            body: "Body B",
            versionLabel: nil,
            publishedAt: "also-not-a-valid-date",
            linkedRequests: []
        )

        let expectedIDs = ["entry-b", "entry-a"]
        #expect(FeedbackClient.sortChangelogEntries([entryA, entryB]).map(\.id) == expectedIDs)
        #expect(FeedbackClient.sortChangelogEntries([entryB, entryA]).map(\.id) == expectedIDs)
    }
}

// MARK: - JSON Fixtures

private func makeColumnJSON(id: String, position: Int) -> [String: Any] {
    [
        "id": id,
        "appId": "app-1",
        "name": "Column \(id)",
        "slug": id,
        "position": position,
        "isVisible": true,
        "isSystem": false,
        "kind": "normal",
        "createdAt": "2026-01-01T00:00:00.000Z",
        "updatedAt": "2026-01-01T00:00:00.000Z"
    ]
}

private func makeVersionJSON(id: String, position: Int) -> [String: Any] {
    [
        "id": id,
        "appId": "app-1",
        "label": id,
        "position": position,
        "released": true,
        "releasedAt": "2026-01-15T00:00:00.000Z",
        "description": NSNull(),
        "createdAt": "2026-01-01T00:00:00.000Z",
        "updatedAt": "2026-01-01T00:00:00.000Z"
    ]
}

private func makeEntryJSON(id: String, publishedAt: String) -> [String: Any] {
    [
        "id": id,
        "title": "Title \(id)",
        "body": "Body for \(id)",
        "versionLabel": "1.0",
        "publishedAt": publishedAt,
        "linkedRequests": []
    ]
}
