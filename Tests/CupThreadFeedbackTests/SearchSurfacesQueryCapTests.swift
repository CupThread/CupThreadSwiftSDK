import Foundation
import SwiftUI
import Testing
@testable import CupThreadFeedback

/// Issue #610: the search term a surface sends must be the live contract's
/// capped form, and the throttle key it is admitted under must describe that
/// same request. Both search surfaces derive their wire term, throttle key,
/// and executed-query bookkeeping from one computed property
/// (`sentSearchText`), so an over-long paste or deep-link
/// `initialSearchText` is searched as the prefix
/// ``FeatureRequestSearchLimits/maxQueryLength`` accepts — one admission slot
/// spent on a request that can actually succeed — instead of on the
/// guaranteed server rejection the raw term earns.
///
/// A view outside a SwiftUI hierarchy cannot persist `@State` writes (see
/// the test-support hooks on the views), so the stub's request log and the
/// injected throttle's window are the observables.
@Suite("Search Surfaces Query Cap", .serialized)
struct SearchSurfacesQueryCapTests {
    static let apiHost = "search-query-cap.example.com"

    /// Thread-safe request log; the URLProtocol handler runs off the test actor.
    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [String] = []
        func record(url: String?) {
            lock.lock()
            defer { lock.unlock() }
            requests.append(url ?? "")
        }
        var urls: [String] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }
    }

    private func makeConfig() -> PublicAppConfig {
        PublicAppConfig(
            appId: "app-1",
            appKey: "app_testkey123456",
            slug: "demo",
            name: "Demo",
            allowPublic: true,
            allowedPlatforms: nil,
            allowedPlatformValues: [],
            allowAnonymousRoadmap: true,
            allowAnonymousVote: true,
            allowAnonymousFeedback: true,
            allowAnonymousChangelog: true
        )
    }

    /// Answers the board's column fetch and both surfaces' list fetch so a
    /// driven load completes cleanly on an empty result set.
    private func stubEmptyResults() -> RequestLog {
        let log = RequestLog()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            log.record(url: request.url?.absoluteString)
            let path = request.url?.path ?? ""
            let body: [String: Any] = path.hasSuffix("/columns")
                ? ["columns": []]
                : ["requests": [], "total": 0]
            return (makeHTTPResponse(), try encodeJSON(body))
        }
        return log
    }

    private func sentQueryTerm(in log: RequestLog) throws -> String? {
        let listURLs = log.urls.filter { $0.contains("q=") }
        let last = try #require(listURLs.last)
        let components = try #require(URLComponents(string: last))
        return try #require(components.queryItems?.first { $0.name == "q" }?.value)
    }

    /// The feature-request list searched an over-long `initialSearchText` as
    /// the capped prefix, spending exactly one admission slot for it.
    @MainActor
    @Test func featureRequestsListSendsCappedQueryForOverLongInitialSearchText() async throws {
        let log = stubEmptyResults()
        let throttle = SearchRequestThrottle()
        let view = FeatureRequestsView(
            client: makeClient(
                baseURL: URL(string: "https://\(Self.apiHost)")!,
                searchThrottle: throttle
            ),
            userToken: "tok",
            configOverride: makeConfig(),
            initialSearchText: String(repeating: "x", count: 300)
        )

        await view.loadFeatureRequestsForTesting()

        let term = try sentQueryTerm(in: log)
        #expect(term == String(repeating: "x", count: FeatureRequestSearchLimits.maxQueryLength))
        #expect(await throttle.admittedCount == 1)
        #expect(await throttle.isDuplicateKey("features|true|\(term ?? "")|"))
    }

    /// The roadmap board paginates an over-long term as the capped prefix on
    /// every cursor page, with the throttle key derived from that same term.
    @MainActor
    @Test func roadmapBoardSendsCappedQueryForOverLongInitialSearchText() async throws {
        let log = stubEmptyResults()
        let throttle = SearchRequestThrottle()
        let view = RoadmapBoardView(
            client: makeClient(
                baseURL: URL(string: "https://\(Self.apiHost)")!,
                searchThrottle: throttle
            ),
            userToken: "tok",
            initialSearchText: String(repeating: "x", count: 300),
            initialGroups: nil,
            configOverride: makeConfig(),
            preResolvedAuthentication: true
        )

        await view.loadForTesting()

        let term = try sentQueryTerm(in: log)
        #expect(term == String(repeating: "x", count: FeatureRequestSearchLimits.maxQueryLength))
        #expect(await throttle.admittedCount == 1)
        #expect(await throttle.isDuplicateKey("roadmap|\(term ?? "")"))
    }
}
