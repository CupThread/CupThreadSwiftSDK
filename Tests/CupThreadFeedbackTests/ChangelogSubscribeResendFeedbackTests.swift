import Foundation
import Testing
@testable import CupThreadFeedback

// Regression suite for issue #373: the pending manage phase's resend action
// used to silently revert to its idle state on success, leaving users unsure
// whether the confirmation email went out and inviting blind retries. The
// model now affirms a successful dispatch (`hasResentConfirmation`) and
// withdraws it when a new attempt starts, so the sheet can render honest
// feedback that always describes the latest request.
@Suite("ChangelogSubscribeResendFeedback")
struct ChangelogSubscribeResendFeedbackTests {
    static let apiHost = "resend-feedback.example.com"
    static let pendingSince = Date(timeIntervalSince1970: 1_760_000_000)

    private func makeModel() -> ChangelogSubscribeModel {
        ChangelogSubscribeModel(
            record: ChangelogSubscriptionRecord(
                email: "user@example.com", state: .pending(since: Self.pendingSince)
            )
        )
    }

    // MARK: - State machine

    /// A successful resend affirms the dispatch instead of silently
    /// reverting the button: the feedback flag flips on, the in-flight flag
    /// clears, and the pending phase (and its resend affordance) stay put.
    @Test func successfulResendAffirmsDispatchAndKeepsPendingPhase() {
        var model = makeModel()

        model.willResendConfirmation()
        #expect(model.isResending)
        #expect(!model.hasResentConfirmation, "No outcome is affirmed while the attempt is in flight")
        #expect(model.phase == .managePending)

        model.didResendConfirmation()
        #expect(model.hasResentConfirmation, "Success must affirm the dispatch for the sheet to render")
        #expect(!model.isResending)
        #expect(model.phase == .managePending, "The resend never leaves the pending manage phase")
        #expect(model.showsResendConfirmation)
        #expect(model.primaryAction == .close)
    }

    /// The affirmation describes the *latest* attempt: starting a new resend
    /// withdraws a previous success so a later failure cannot appear to have
    /// re-sent the email.
    @Test func newResendAttemptWithdrawsPreviousConfirmation() {
        var model = makeModel()

        model.willResendConfirmation()
        model.didResendConfirmation()
        #expect(model.hasResentConfirmation)

        model.willResendConfirmation()
        #expect(!model.hasResentConfirmation, "A new attempt must withdraw the stale affirmation")
        #expect(model.isResending)
    }

    /// "Use a Different Email" starts a blank form with no stale resend
    /// feedback carried over from the pending phase.
    @Test func startNewEmailEntryClearsResendConfirmation() {
        var model = makeModel()
        model.willResendConfirmation()
        model.didResendConfirmation()
        #expect(model.hasResentConfirmation)

        model.startNewEmailEntry()

        #expect(model.phase == .form)
        #expect(!model.hasResentConfirmation)
        #expect(!model.isResending)
    }

    /// A fresh presentation never opens with the affirmation set — the
    /// feedback describes one sheet's lifetime only.
    @Test func freshModelHasNoResendConfirmation() {
        #expect(!makeModel().hasResentConfirmation)
        #expect(!ChangelogSubscribeModel(record: nil).hasResentConfirmation)
    }

    // MARK: - Network-level lifecycle

    /// Drives exactly what `ChangelogSubscribeView.resendConfirmation()`
    /// performs around the network call: a success affirms the dispatch for
    /// the sheet's confirmation banner, and a failure after a prior success
    /// leaves no stale affirmation — the banner slot then shows the error
    /// instead.
    @Test func resendLifecycleTracksAffirmationAcrossSuccessAndFailure() async throws {
        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!)
        var model = makeModel()

        // First attempt succeeds, mirroring the view's success path.
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 201), try encodeJSON(["subscribed": true]))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.apiHost, nil) }

        model.willResendConfirmation()
        _ = try await client.subscribeToChangelog(email: model.rememberedEmail, userToken: "user-token")
        model.didResendConfirmation()
        #expect(model.hasResentConfirmation)
        #expect(!model.isResending)

        // Second attempt fails: the new attempt withdrew the affirmation and
        // the failure path must not re-assert it.
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 429), try encodeJSON(["error": "slow down"]))
        }
        model.willResendConfirmation()
        #expect(!model.hasResentConfirmation, "The new attempt withdraws the previous affirmation")
        do {
            _ = try await client.subscribeToChangelog(email: model.rememberedEmail, userToken: "user-token")
            Issue.record("The 429 response must throw")
        } catch {
            #expect(!FriendlyError.message(for: error).isEmpty)
        }
        model.isResending = false // the view's defer path
        #expect(!model.hasResentConfirmation, "A failed resend must not affirm the dispatch")
        #expect(model.phase == .managePending)
        #expect(model.showsResendConfirmation)
    }
}
