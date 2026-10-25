import Foundation
import Testing
@testable import CupThreadFeedback

@Suite("Search Admission Verdict Tests")
struct SearchAdmissionVerdictTests {
    @Test func duplicateQuerySkipDoesNotProduceRateLimitOutcome() async throws {
        let throttle = SearchRequestThrottle(minimumInterval: .seconds(1.5))

        // First query is admitted
        #expect(await throttle.admissionVerdict(key: "query_1") == .admitted)

        // Immediate second query with identical key is skipped as duplicate,
        // and that skip must NOT surface a rate-limited outcome to the UI.
        let secondVerdict = try #require(await throttle.admissionVerdict(key: "query_1"))
        #expect(secondVerdict == .duplicateSkipped)
        #expect(SearchAdmissionOutcome.outcome(for: secondVerdict, hasExistingContent: true) == nil)
        #expect(SearchAdmissionOutcome.outcome(for: secondVerdict, hasExistingContent: false) == nil)
    }

    @Test func admissionVerdictDistinguishesDuplicateFromRateLimitedAndAdmitted() async throws {
        let throttle = SearchRequestThrottle(minimumInterval: .seconds(1.5))

        // 1. First fetch is admitted
        let firstVerdict = try #require(await throttle.admissionVerdict(key: "query_1"))
        #expect(firstVerdict == .admitted)
        #expect(SearchAdmissionOutcome.outcome(for: firstVerdict, hasExistingContent: true) == nil)
        #expect(SearchAdmissionOutcome.outcome(for: firstVerdict, hasExistingContent: false) == nil)

        // 2. Immediate duplicate fetch returns duplicateSkipped
        let secondVerdict = try #require(await throttle.admissionVerdict(key: "query_1"))
        #expect(secondVerdict == .duplicateSkipped)
        #expect(SearchAdmissionOutcome.outcome(for: secondVerdict, hasExistingContent: true) == nil)
        #expect(SearchAdmissionOutcome.outcome(for: secondVerdict, hasExistingContent: false) == nil)

        // 3. Post-429 cooldown returns rateLimited and surfaces user notices
        await throttle.enterCooldown()
        let thirdVerdict = try #require(await throttle.admissionVerdict(key: "query_2"))
        #expect(thirdVerdict == .rateLimited)
        let expectedNotice = CupThreadStrings.tr("cupthread.search.rate_limited")
        #expect(SearchAdmissionOutcome.outcome(for: thirdVerdict, hasExistingContent: true) == .inlineNotice(expectedNotice))
        #expect(SearchAdmissionOutcome.outcome(for: thirdVerdict, hasExistingContent: false) == .fullScreenError(expectedNotice))
    }

    /// A cancelled wait reaches no verdict at all: the throttle answers `nil`
    /// rather than a denial, so a surface returns before it ever consults
    /// ``SearchAdmissionOutcome`` and writes no state.
    @Test func cancelledWaitYieldsNoVerdict() async {
        let throttle = SearchRequestThrottle(
            minimumInterval: .seconds(3600),
            sleepUntil: { _ in throw CancellationError() }
        )
        #expect(await throttle.admissionVerdict(key: "query_1") == .admitted)
        // A different key inside the spacing interval must wait; that wait is
        // cancelled, so the result is `nil` — not `.rateLimited`.
        #expect(await throttle.admissionVerdict(key: "query_2") == nil)
    }

    @Test func isDuplicateKeyReflectsLastAdmittedKey() async {
        let throttle = SearchRequestThrottle(minimumInterval: .seconds(1.5))
        #expect(await throttle.isDuplicateKey("query_1") == false)
        #expect(await throttle.waitForAdmission(key: "query_1"))
        #expect(await throttle.isDuplicateKey("query_1") == true)
        #expect(await throttle.isDuplicateKey("query_2") == false)
    }
}
