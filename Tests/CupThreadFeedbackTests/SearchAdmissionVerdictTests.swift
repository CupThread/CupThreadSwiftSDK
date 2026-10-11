import Foundation
import Testing
@testable import CupThreadFeedback

@Suite("Search Admission Verdict Tests")
struct SearchAdmissionVerdictTests {
    @Test func duplicateQuerySkipDoesNotProduceRateLimitOutcome() async {
        let throttle = SearchRequestThrottle(minimumInterval: .seconds(1.5))

        // First query is admitted
        let firstAdmitted = await throttle.waitForAdmission(key: "query_1")
        #expect(firstAdmitted)

        // Immediate second query with identical key is skipped as duplicate
        let secondAdmitted = await throttle.waitForAdmission(key: "query_1")
        #expect(!secondAdmitted)

        // A duplicate skip must NOT surface a rate-limited outcome to the UI
        // When checking whether an admission outcome should be presented for duplicate skips:
        let outcome = SearchAdmissionOutcome.outcomeForDuplicateSkip()
        #expect(outcome == nil)
    }

    @Test func admissionVerdictDistinguishesDuplicateFromRateLimitedAndAdmitted() async {
        let throttle = SearchRequestThrottle(minimumInterval: .seconds(1.5))

        // 1. First fetch is admitted
        let firstVerdict = await throttle.admissionVerdict(key: "query_1")
        #expect(firstVerdict == .admitted)
        #expect(SearchAdmissionOutcome.outcome(for: firstVerdict, hasExistingContent: true) == nil)
        #expect(SearchAdmissionOutcome.outcome(for: firstVerdict, hasExistingContent: false) == nil)

        // 2. Immediate duplicate fetch returns duplicateSkipped
        let secondVerdict = await throttle.admissionVerdict(key: "query_1")
        #expect(secondVerdict == .duplicateSkipped)
        #expect(SearchAdmissionOutcome.outcome(for: secondVerdict, hasExistingContent: true) == nil)
        #expect(SearchAdmissionOutcome.outcome(for: secondVerdict, hasExistingContent: false) == nil)
        #expect(SearchAdmissionOutcome.outcome(wasAdmitted: false, isCancelled: false, hasExistingContent: true, isDuplicate: true) == nil)
        #expect(SearchAdmissionOutcome.outcome(wasAdmitted: false, isCancelled: false, hasExistingContent: false, isDuplicate: true) == nil)
        #expect(SearchAdmissionOutcome.outcome(isCancelled: false, hasExistingContent: true, isDuplicate: true) == nil)
        #expect(SearchAdmissionOutcome.outcome(isCancelled: false, hasExistingContent: false, isDuplicate: true) == nil)

        // 3. Post-429 cooldown returns rateLimited and surfaces user notices
        await throttle.enterCooldown()
        let thirdVerdict = await throttle.admissionVerdict(key: "query_2")
        #expect(thirdVerdict == .rateLimited)
        let expectedNotice = CupThreadStrings.tr("cupthread.search.rate_limited")
        #expect(SearchAdmissionOutcome.outcome(for: thirdVerdict, hasExistingContent: true) == .inlineNotice(expectedNotice))
        #expect(SearchAdmissionOutcome.outcome(for: thirdVerdict, hasExistingContent: false) == .fullScreenError(expectedNotice))
    }

    @Test func cancellationVerdictProducesNoOutcome() async {
        #expect(SearchAdmissionOutcome.outcome(for: nil, hasExistingContent: true) == nil)
        #expect(SearchAdmissionOutcome.outcome(for: nil, hasExistingContent: false) == nil)
    }

    @Test func isDuplicateKeyReflectsLastAdmittedKey() async {
        let throttle = SearchRequestThrottle(minimumInterval: .seconds(1.5))
        #expect(await throttle.isDuplicateKey("query_1") == false)
        #expect(await throttle.waitForAdmission(key: "query_1"))
        #expect(await throttle.isDuplicateKey("query_1") == true)
        #expect(await throttle.isDuplicateKey("query_2") == false)
    }
}
