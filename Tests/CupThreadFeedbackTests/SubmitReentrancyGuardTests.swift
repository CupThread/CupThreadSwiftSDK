import Foundation
import SwiftUI
import Testing
@testable import CupThreadFeedback

// MARK: - Submission re-entrancy guards (issue #581, #539 parity)

/// Pins the re-entrancy contract the feedback composer has had since #539:
/// `FeatureRequestComposeView.submit()` and `CommentsView.submitComment()`
/// must refuse a second entry while one submission is in flight, and the
/// feature-request composer must refuse to replace a pending Turnstile
/// challenge. `.disabled(...)` only repaints after the runloop turn, so two
/// taps delivered in the same runloop turn both reach these methods before
/// the button's enabled state updates — and the feature-request intake has
/// no idempotency key, so the duplicates become two pending proposals.
///
/// SwiftUI `@State` writes are not observable on a unit-constructed view
/// (concurrent `submit()` invocations each see the initial value), so the
/// guards are pinned with the source-scan pattern the sibling view tests use;
/// the runtime test covers what the harness *can* observe — that a settled
/// submission frees the entry for the next attempt, the same settle→resume
/// shape the Turnstile retry path depends on.
@Suite("Submission re-entrancy guards")
struct SubmitReentrancyGuardTests {
    private func makeConfig(allowAnonymousFeedback: Bool = true) -> PublicAppConfig {
        PublicAppConfig(
            appId: "app-1",
            appKey: "app_testkey123456",
            slug: "demo",
            name: "Demo",
            allowPublic: true,
            allowAnonymousFeedback: allowAnonymousFeedback
        )
    }

    // MARK: Feature-request composer: the submit entry refuses re-entrancy

    @Test func submitRefusesASecondEntryWhileOneIsInFlight() throws {
        let body = try Self.functionBody(named: "func submit(turnstileToken: String? = nil) async", in: try Self.composeViewSource())
        let guardRange = try #require(
            body.range(of: "guard !isSubmitting"),
            "submit() must refuse a second entry while one submission is in flight (#581, mirroring FeedbackComposerView)"
        )
        let flagSet = try #require(
            body.range(of: "isSubmitting = true"),
            "submit() must still mark the submission in flight"
        )
        #expect(
            flagSet.lowerBound > guardRange.lowerBound,
            "the re-entrancy check must run before isSubmitting is (re)set (#581)"
        )
    }

    // MARK: Comments: the submit entry refuses re-entrancy

    @Test func submitCommentRefusesASecondEntryWhileOneIsInFlight() throws {
        let content = try Self.source("CommentsView.swift")
        let body = try Self.functionBody(named: "func submitComment() async", in: content)
        let guardRange = try #require(
            body.range(of: "guard !isSubmitting"),
            "submitComment() must refuse a second entry while one submission is in flight (#581, mirroring FeedbackComposerView)"
        )
        let flagSet = try #require(
            body.range(of: "isSubmitting = true"),
            "submitComment() must still mark the submission in flight"
        )
        #expect(
            flagSet.lowerBound > guardRange.lowerBound,
            "the re-entrancy check must run before isSubmitting is (re)set (#581)"
        )
    }

    // MARK: Feature-request composer: a second gated failure keeps the challenge

    @Test func featureRequestComposerRefusesASecondChallengeWhileOneIsPending() throws {
        // The first challenge owns the sheet; a second gated failure must let
        // its attempt fall through to the normal `submitError` copy instead
        // of overwriting `pendingChallenge` — that would tear down the
        // presented widget mid-mint and drop the first challenge's `resume`
        // closure unrun (#581, mirroring #539). Pinned source-side, matching
        // `composerRefusesASecondChallengeWhileOneIsPending`.
        let content = try Self.composeViewSource()
        let helper = try #require(
            content.range(of: "private func presentChallengeIfNeeded"),
            "the challenge helper was renamed; update this scan"
        )
        let helperBody = content[helper.lowerBound...]

        let guardRange = try #require(
            helperBody.range(of: "guard pendingChallenge == nil else { return false }"),
            "a second gated failure must not replace a pending challenge (#581)"
        )
        let registration = try #require(
            helperBody.range(of: "pendingChallenge = PendingTurnstileChallenge("),
            "the helper must still register the challenge it resolved"
        )
        #expect(
            registration.lowerBound > guardRange.lowerBound,
            "the refusal guard must run before the registration overwrites pendingChallenge (#581)"
        )
    }

    // MARK: Runtime: a settled submission frees the entry

    @Test @MainActor func sequentialRetryAfterSettlementStillReachesTheNetwork() async throws {
        // The guard must not over-block: a submit that has fully settled
        // (failed here; the Turnstile resume path calls with a token after
        // the same settle) frees the entry for the next attempt. Dedicated
        // mock host: MockURLProtocol handlers are keyed by host and suites
        // run in parallel.
        let host = "reentry-compose-retry.test.example.com"
        let capture = CaptureBox<[URLRequest]>()
        let receipt: [String: Any] = ["featureRequestId": "fr_reentry_2", "pending": true]
        MockURLProtocol.setHandler(forHost: host) { request in
            capture.value = (capture.value ?? []) + [request]
            if (capture.value ?? []).count == 1 {
                return (makeHTTPResponse(status: 500), try encodeJSON(["error": "boom"]))
            }
            return (makeHTTPResponse(status: 201), try encodeJSON(receipt))
        }
        defer { MockURLProtocol.setHandler(forHost: host, nil) }

        var didSubmit = false
        let view = FeatureRequestComposeView(
            client: makeClient(baseURL: URL(string: "https://\(host)")!),
            userToken: "test_token",
            config: makeConfig(),
            initialDraft: FeatureRequestDraft(title: "Dark mode support", description: "Please add dark mode.")
        ) { didSubmit = true }

        await view.submit()
        await view.submit()

        let requests = try #require(capture.value)
        #expect(requests.count == 2, "a settled submission must not wedge the composer")
        #expect(didSubmit, "the retry must fire onSubmitted once accepted")
    }

    // MARK: Fixtures

    private static func composeViewSource() throws -> String {
        try source("FeatureRequestComposeView.swift")
    }

    /// Reads an SDK source file relative to this test file, walking up to the
    /// package root (Swift Testing `#filePath` lands deep in DerivedData).
    private static func source(_ name: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            directory.deleteLastPathComponent()
            let candidate = directory
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("CupThreadFeedback", isDirectory: true)
                .appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }

    /// The body of the first function whose declaration starts with `marker`,
    /// located by brace matching so the scan stays inside the intended
    /// function even when sibling functions contain similar statements.
    private static func functionBody(named marker: String, in content: String) throws -> Substring {
        let start = try #require(
            content.range(of: marker),
            "the \(marker) anchor was renamed; update this scan"
        )
        let remainder = content[start.upperBound...]
        var depth = 0
        var started = false
        var index = remainder.startIndex
        while index < remainder.endIndex {
            let character = remainder[index]
            if character == "{" {
                depth += 1
                started = true
            } else if character == "}" {
                depth -= 1
                if started && depth == 0 {
                    return remainder[..<index]
                }
            }
            index = remainder.index(after: index)
        }
        return remainder
    }
}
