import Foundation
import Testing
@testable import CupThreadFeedback

/// Cover the failed-vote presentation contract (#36): every real vote
/// failure surfaces a transient notice (rate-limit copy for HTTP 429,
/// generic copy otherwise) while cancellation stays silent. The revert
/// itself — vote fields restored, in-flight guard cleared, concurrent
/// reloads preserved — is covered by `FeatureRequestsListStateTests`.
@Suite("Feature vote failure presentation")
struct FeatureVoteFailureTests {
    @Test func classifierMapsVoteErrorsToPresentations() {
        #expect(VoteFailureNotice.notice(for: CancellationError()) == .silent)
        #expect(VoteFailureNotice.notice(for: URLError(.cancelled)) == .silent)
        #expect(VoteFailureNotice.notice(for: URLError(.notConnectedToInternet)) == .generic)
        #expect(VoteFailureNotice.notice(for: URLError(.timedOut)) == .generic)
        #expect(
            VoteFailureNotice.notice(for: FeedbackClientError.rateLimited(message: nil, requestId: nil))
                == .rateLimited
        )
        #expect(
            VoteFailureNotice.notice(
                for: FeedbackClientError.unexpectedStatus(code: 500, message: "boom", requestId: nil)
            ) == .generic
        )
        #expect(
            VoteFailureNotice.notice(
                for: FeedbackClientError.unexpectedStatus(code: 403, message: "voting disabled", requestId: nil)
            ) == .generic
        )
        #expect(VoteFailureNotice.notice(for: FeedbackClientError.invalidResponse) == .generic)
    }

    @Test func noticeMessagesResolveLocalizedCopy() {
        #expect(VoteFailureNotice.silent.message.isEmpty)
        #expect(
            VoteFailureNotice.rateLimited.message
                == CupThreadStrings.tr("cupthread.features.vote_rate_limited")
        )
        #expect(
            VoteFailureNotice.generic.message
                == CupThreadStrings.tr("cupthread.features.vote_failed")
        )
    }

    @Test func genericVoteFailureCopyShipsInEveryTargetLanguage() throws {
        let languages = ["en", "zh-Hans", "zh-Hant", "zh-HK", "zh-TW", "ja", "ko", "fr", "es", "de",
                         "de-CH", "it", "pt", "pl", "nb", "no", "da", "tr", "vi"]
        for lang in languages {
            let url = try #require(
                Bundle.module.url(
                    forResource: "Localizable", withExtension: "strings",
                    subdirectory: nil, localization: lang
                ),
                "Missing Localizable.strings for \(lang)"
            )
            let data = try Data(contentsOf: url)
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            let dict = try #require(plist as? [String: String])
            let value = try #require(dict["cupthread.features.vote_failed"], "\(lang) missing vote_failed")
            #expect(!value.isEmpty, "\(lang) vote_failed copy is empty")
            #expect(!value.contains("cupthread."), "\(lang) vote_failed leaked the raw key")
        }
    }
}
