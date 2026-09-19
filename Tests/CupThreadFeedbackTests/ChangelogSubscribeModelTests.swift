import Foundation
import Testing
@testable import CupThreadFeedback

// Regression suite for issue #32: the subscribe sheet must keep a close
// affordance in every phase and must never reach the unsubscribe endpoint,
// so macOS/tvOS/visionOS users (no swipe-to-dismiss) can always leave the
// sheet in one tap without destroying their subscription.
@Suite("ChangelogSubscribeModel", .serialized)
struct ChangelogSubscribeModelTests {
    static let apiHost = "subscribe-model.example.com"

    private func makeModel(in phase: ChangelogSubscribePhase) -> ChangelogSubscribeModel {
        var model = ChangelogSubscribeModel(
            subscribedEmail: phase == .manage ? "user@example.com" : nil
        )
        if phase == .subscribed {
            model.didSubscribe()
        }
        return model
    }

    // MARK: - Toolbar decisions

    @Test func everyPhaseShowsACloseAffordance() {
        for phase in [ChangelogSubscribePhase.form, .subscribed, .manage] {
            #expect(
                makeModel(in: phase).showsClose,
                "Phase \(phase) lost its dismissal affordance — users on macOS/tvOS/visionOS would be trapped"
            )
        }
    }

    @Test func onlyTheFormPhasePerformsNetworkWork() {
        // Exhaustive decision table for the primary button. `.close` must be
        // the modeled action in every post-subscribe phase so closing the
        // sheet never depends on a network call.
        #expect(makeModel(in: .form).primaryAction == .subscribe)
        #expect(makeModel(in: .subscribed).primaryAction == .close)
        #expect(makeModel(in: .manage).primaryAction == .close)
    }

    @Test func subscribedAndManageCloseWithoutSideEffects() {
        for phase in [ChangelogSubscribePhase.subscribed, .manage] {
            let model = makeModel(in: phase)
            #expect(model.primaryAction == .close)
            #expect(model.primaryTitle == CupThreadStrings.tr("cupthread.subscribe.done_button"))
            // The close button must never be blocked, even when leftover
            // form state (or none) would fail email validation.
            #expect(!model.isPrimaryDisabled)
        }
    }

    // MARK: - Form phase

    @Test func formPrimaryButtonFollowsEmailValidity() {
        var model = makeModel(in: .form)
        #expect(model.primaryTitle == CupThreadStrings.tr("cupthread.subscribe.subscribe_button"))

        model.email = "not-an-email"
        #expect(!model.isValidEmail)
        #expect(model.isPrimaryDisabled)

        model.email = "user@example.com"
        #expect(model.isValidEmail)
        #expect(!model.isPrimaryDisabled)
    }

    @Test func formPrimaryButtonShowsProgressWhileWorking() {
        var model = makeModel(in: .form)
        model.email = "user@example.com"
        model.isWorking = true
        #expect(model.primaryTitle == CupThreadStrings.tr("cupthread.subscribe.subscribing_button"))
        #expect(model.isPrimaryDisabled)
    }

    @Test func trimmedEmailStripsWhitespace() {
        var model = makeModel(in: .form)
        model.email = "  user@example.com\n"
        #expect(model.trimmedEmail == "user@example.com")
    }

    @Test func emailValidationRejectsMalformedShapes() {
        var model = makeModel(in: .form)

        model.email = "user@example.com"
        #expect(model.isValidEmail)

        model.email = "user@example" // no dot after the @
        #expect(!model.isValidEmail)

        model.email = "@example.com" // missing local part
        #expect(!model.isValidEmail)

        model.email = "user@" // missing domain
        #expect(!model.isValidEmail)

        model.email = "user@example .com" // embedded whitespace
        #expect(!model.isValidEmail)
    }

    // MARK: - State machine

    @Test func didSubscribeTransitionsToSubscribedAndClearsWorking() {
        var model = makeModel(in: .form)
        model.email = "user@example.com"
        model.isWorking = true

        model.didSubscribe()

        #expect(model.phase == .subscribed)
        #expect(!model.isWorking)
        #expect(model.primaryAction == .close)
        // The subscribed address stays available for the confirmation copy.
        #expect(model.trimmedEmail == "user@example.com")
    }

    @Test func startNewEmailEntryReturnsToBlankForm() {
        var model = makeModel(in: .manage)
        #expect(model.phase == .manage)

        model.startNewEmailEntry()

        #expect(model.phase == .form)
        #expect(model.email.isEmpty)
        #expect(!model.isWorking)
        #expect(model.primaryAction == .subscribe)
    }

    @Test func initialPhaseOpensFormWithoutStoredEmailAndManageWithOne() {
        #expect(
            ChangelogSubscribeModel(subscribedEmail: nil).phase == .form
        )
        #expect(
            ChangelogSubscribeModel(subscribedEmail: "user@example.com").phase == .manage
        )
        #expect(ChangelogSubscribeModel.initialPhase(subscribedEmail: nil) == .form)
        #expect(ChangelogSubscribeModel.initialPhase(subscribedEmail: "user@example.com") == .manage)
    }

    // MARK: - Network-level lifecycle

    /// Records the path of every request that reaches the mock host.
    private final class RequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []

        func append(_ path: String) {
            lock.lock()
            defer { lock.unlock() }
            paths.append(path)
        }

        func snapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return paths
        }
    }

    @Test func subscribeThenCloseSequenceNeverHitsUnsubscribeEndpoint() async throws {
        let recorder = RequestRecorder()
        let lastRequest = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            recorder.append(request.url?.path ?? "")
            lastRequest.value = request
            return (makeHTTPResponse(status: 201), try encodeJSON(["subscribed": true]))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.apiHost, nil) }

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!)
        var model = ChangelogSubscribeModel(subscribedEmail: nil)
        model.email = "  user@example.com  "

        // Drives exactly what the view performs for each modeled action:
        // `.subscribe` calls the client, `.close` performs nothing but a
        // dismiss — and `ChangelogSubscribeAction` has no case that could
        // reach the unsubscribe endpoint at all.
        guard case .subscribe = model.primaryAction else {
            Issue.record("Form phase must model .subscribe")
            return
        }
        _ = try await client.subscribeToChangelog(email: model.trimmedEmail, userToken: "user-token")
        model.didSubscribe()

        guard case .close = model.primaryAction else {
            Issue.record("Subscribed phase must model .close")
            return
        }
        // Closing performs no client call whatsoever.

        let paths = recorder.snapshot()
        #expect(paths == ["/api/v1/public/apps/app_testkey123456/changelog/subscribe"])
        #expect(
            !paths.contains { $0.contains("unsubscribe") },
            "The subscribe sheet lifecycle must never touch the unsubscribe endpoint"
        )

        let request = try #require(lastRequest.value)
        let body = try #require(bodyData(from: request))
        let payload = try #require(parseJSONDict(body))
        #expect(payload["email"] as? String == "user@example.com", "The email must be sent trimmed")
    }

    @Test func manageToNewEmailToSubscribeSequenceNeverHitsUnsubscribeEndpoint() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            recorder.append(request.url?.path ?? "")
            return (makeHTTPResponse(status: 201), try encodeJSON(["subscribed": true]))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.apiHost, nil) }

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!)
        var model = ChangelogSubscribeModel(subscribedEmail: "old@example.com")
        #expect(model.phase == .manage)
        #expect(model.primaryAction == .close) // returning user can close immediately

        model.startNewEmailEntry()
        model.email = "new@example.com"

        guard case .subscribe = model.primaryAction else {
            Issue.record("Form phase must model .subscribe")
            return
        }
        _ = try await client.subscribeToChangelog(email: model.trimmedEmail, userToken: "user-token")
        model.didSubscribe()
        #expect(model.primaryAction == .close) // close again without network work

        #expect(
            !recorder.snapshot().contains { $0.contains("unsubscribe") },
            "The manage → new email → subscribe sequence must never touch the unsubscribe endpoint"
        )
    }
}
