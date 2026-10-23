import Foundation
import SwiftUI
import Testing
@testable import CupThreadFeedback

// Issue #529: `SearchRequestThrottle` lives for the lifetime of a
// `FeedbackClient`, so a `.duplicateSkipped` verdict can belong to a previous
// surface instance (deep-link re-entry, a second window, or a presentation
// whose load was cancelled mid-fetch). Both surfaces used to return without
// any state write and keep their first-load skeleton forever. Silent skips
// are now limited to surfaces that already rendered the exact throttle key;
// every other duplicate skip clears the gate and loads.

@Suite("Search duplicate-skip policy")
struct SearchDuplicateSkipPolicyTests {
    private let key = "features|true|dark|"

    @Test func freshSurfaceReloadsEvenWhenTheKeyWasAdmitted() {
        #expect(
            SearchDuplicateSkipPolicy.decision(
                hasLoadedOnce: false,
                lastExecutedKey: nil,
                currentKey: key
            ) == .reload
        )
    }

    @Test func cancelledPredecessorReloadsEvenWithAKeyedListState() {
        // A cancelled load never reaches a verdict, so `hasLoadedOnce` stays
        // false even though the throttle admitted (and recorded) the key.
        #expect(
            SearchDuplicateSkipPolicy.decision(
                hasLoadedOnce: false,
                lastExecutedKey: key,
                currentKey: key
            ) == .reload
        )
    }

    @Test func renderedKeyIsHonoredSilently() {
        #expect(
            SearchDuplicateSkipPolicy.decision(
                hasLoadedOnce: true,
                lastExecutedKey: key,
                currentKey: key
            ) == .honor
        )
    }

    @Test func renderedDifferentQueryReloads() {
        #expect(
            SearchDuplicateSkipPolicy.decision(
                hasLoadedOnce: true,
                lastExecutedKey: "features|true|light|",
                currentKey: key
            ) == .reload
        )
    }

    @Test func renderedDifferentVersionFilterReloads() {
        // Same query text, different version filter: the throttle keys differ,
        // and so do the results the surface is showing.
        #expect(
            SearchDuplicateSkipPolicy.decision(
                hasLoadedOnce: true,
                lastExecutedKey: "features|true|dark|v1",
                currentKey: key
            ) == .reload
        )
    }

    @Test func renderedDifferentRoadmapAccessVerdictReloads() {
        // The config switch is part of the key: results fetched while
        // anonymous roadmap access was allowed are not a verdict for the
        // locked-down key.
        #expect(
            SearchDuplicateSkipPolicy.decision(
                hasLoadedOnce: true,
                lastExecutedKey: "features|true|dark|",
                currentKey: "features|false|dark|"
            ) == .reload
        )
    }
}

@Suite("FeatureRequestsListState executed filter key")
struct FeatureRequestsListStateExecutedKeyTests {
    @Test func replacingPageRecordsTheFilterKey() {
        var state = FeatureRequestsListState()
        state.applyPage(
            makeResult(),
            replacesExisting: true,
            executedQuery: "dark",
            executedFilterKey: "features|true|dark|"
        )
        #expect(state.lastExecutedQuery == "dark")
        #expect(state.lastExecutedFilterKey == "features|true|dark|")
    }

    @Test func appendingPageKeepsTheRenderedFilterKey() {
        var state = FeatureRequestsListState(lastExecutedFilterKey: "features|true|dark|")
        state.applyPage(
            makeResult(),
            replacesExisting: false,
            executedFilterKey: "features|true|other|"
        )
        #expect(state.lastExecutedFilterKey == "features|true|dark|")
    }

    @Test func replacingPageWithoutAKeyPreservesThePreviousKey() {
        var state = FeatureRequestsListState(lastExecutedFilterKey: "features|true|dark|")
        state.applyPage(makeResult(), replacesExisting: true)
        #expect(state.lastExecutedFilterKey == "features|true|dark|")
    }

    private func makeResult() -> ListFeatureRequestsResult {
        ListFeatureRequestsResult(requests: [], total: 0, hasMore: false, nextCursor: nil)
    }
}

@Suite("Fresh-surface duplicate-skip guards")
struct FreshSurfaceDuplicateSkipGuardTests {
    @Test @MainActor func freshFeatureRequestsViewHasNoRenderedKey() {
        let view = FeatureRequestsView(
            client: makeClient(appKey: "app_test_dummy_key_123456"),
            userToken: "test_token",
            initialSearchText: "dark"
        )
        #expect(!view.hasRenderedCurrentSearchKey)
    }

    @Test @MainActor func featureRequestsViewHonorsTheSkipForItsRenderedKey() {
        let view = FeatureRequestsView(
            client: makeClient(appKey: "app_test_dummy_key_123456"),
            userToken: "test_token",
            listState: FeatureRequestsListState(
                lastExecutedQuery: "dark",
                lastExecutedFilterKey: "features|true|dark|"
            ),
            loadState: Self.settledLoadState(),
            initialSearchText: "dark"
        )
        #expect(view.hasRenderedCurrentSearchKey)
    }

    @Test @MainActor func featureRequestsViewDoesNotHonorADifferentQueryKey() {
        let view = FeatureRequestsView(
            client: makeClient(appKey: "app_test_dummy_key_123456"),
            userToken: "test_token",
            listState: FeatureRequestsListState(
                lastExecutedQuery: "light",
                lastExecutedFilterKey: "features|true|light|"
            ),
            loadState: Self.settledLoadState(),
            initialSearchText: "dark"
        )
        #expect(!view.hasRenderedCurrentSearchKey)
    }

    @Test @MainActor func featureRequestsViewDoesNotHonorAKeyFromACancelledLoad() {
        // The key is recorded, but the load never settled — a cancelled
        // predecessor must not make the replacement presentation skip its
        // only automatic loader.
        let view = FeatureRequestsView(
            client: makeClient(appKey: "app_test_dummy_key_123456"),
            userToken: "test_token",
            listState: FeatureRequestsListState(
                lastExecutedQuery: "dark",
                lastExecutedFilterKey: "features|true|dark|"
            ),
            loadState: FeatureRequestsLoadState(),
            initialSearchText: "dark"
        )
        #expect(!view.hasRenderedCurrentSearchKey)
    }

    @Test @MainActor func freshRoadmapBoardHasNoRenderedKey() {
        let board = RoadmapBoardView(
            client: makeClient(appKey: "app_test_dummy_key_123456"),
            userToken: "test_token",
            initialSearchText: "dark",
            initialGroups: nil
        )
        #expect(!board.hasRenderedCurrentSearchKey)
    }

    @Test @MainActor func roadmapBoardHonorsTheSkipForItsRenderedQuery() {
        let board = RoadmapBoardView(
            client: makeClient(appKey: "app_test_dummy_key_123456"),
            userToken: "test_token",
            initialSearchText: "dark",
            initialGroups: []
        )
        #expect(board.hasRenderedCurrentSearchKey)
    }

    @Test @MainActor func roadmapBoardDoesNotHonorAStaleRenderedQuery() {
        // The board still shows the plain listing while the search field
        // already holds a query whose admitted fetch was superseded.
        let board = RoadmapBoardView(
            client: makeClient(appKey: "app_test_dummy_key_123456"),
            userToken: "test_token",
            initialSearchText: "dark",
            initialGroups: [],
            lastExecutedQueryOverride: ""
        )
        #expect(!board.hasRenderedCurrentSearchKey)
    }

    private static func settledLoadState() -> FeatureRequestsLoadState {
        var state = FeatureRequestsLoadState()
        let generation = state.startLoading()
        state.finishLoading(generation: generation, wasCancelled: false)
        return state
    }
}

@Suite("Duplicate-skip recovery wiring")
struct DuplicateSkipRecoveryWiringTests {
    @Test func featureRequestsViewRecoversFreshSurfaceDuplicates() throws {
        let content = try Self.source(named: "FeatureRequestsView.swift")

        let rendered = try Self.functionBody(named: "var hasRenderedCurrentSearchKey: Bool", in: content)
        #expect(rendered.contains("SearchDuplicateSkipPolicy.decision("))

        let recover = try Self.functionBody(named: "func recoversFromDuplicateSkip(", in: content)
        #expect(recover.contains("verdict == .duplicateSkipped"))
        #expect(recover.contains("resetLastAdmittedKey()"))

        let branch = try Self.block(after: "guard verdict == .admitted else", in: content)
        #expect(branch.contains("recoversFromDuplicateSkip(verdict)"))
        #expect(branch.contains("await loadFeatureRequests()"))
        #expect(content.contains("executedFilterKey: filterKey"))
    }

    @Test func roadmapBoardViewRecoversFreshSurfaceDuplicates() throws {
        let content = try Self.source(named: "RoadmapBoardView.swift")

        let rendered = try Self.functionBody(named: "var hasRenderedCurrentSearchKey: Bool", in: content)
        #expect(rendered.contains("SearchDuplicateSkipPolicy.decision("))

        let recover = try Self.functionBody(named: "func recoversFromDuplicateSkip(", in: content)
        #expect(recover.contains("verdict == .duplicateSkipped"))
        #expect(recover.contains("resetLastAdmittedKey()"))

        let branch = try Self.block(after: "guard verdict == .admitted else", in: content)
        #expect(branch.contains("recoversFromDuplicateSkip(verdict)"))
        #expect(branch.contains("await load()"))
    }

    // MARK: - Source fixtures

    private static func source(named file: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            directory.deleteLastPathComponent()
            let candidate = directory
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("CupThreadFeedback", isDirectory: true)
                .appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
        }
        throw SourceScanError.missing(file)
    }

    /// The body of the first declaration whose start matches `marker`.
    private static func functionBody(named marker: String, in content: String) throws -> Substring {
        try block(after: marker, in: content, includingBraces: false)
    }

    /// The brace-delimited block that starts at `marker` (inclusive of the
    /// braces themselves).
    private static func block(
        after marker: String,
        in content: String,
        includingBraces: Bool = true
    ) throws -> Substring {
        let start = try #require(
            content.range(of: marker),
            "the \(marker) anchor was renamed; update this scan"
        )
        let remainder = content[start.upperBound...]
        guard let openBrace = remainder.firstIndex(of: "{") else {
            throw SourceScanError.missing("\(marker) {")
        }
        var depth = 0
        var index = openBrace
        while index < remainder.endIndex {
            let character = remainder[index]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return includingBraces
                        ? remainder[openBrace...index]
                        : remainder[remainder.index(after: openBrace)..<index]
                }
            }
            index = remainder.index(after: index)
        }
        throw SourceScanError.missing("closing brace for \(marker)")
    }

    private enum SourceScanError: Error {
        case missing(String)
    }
}
