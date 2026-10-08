import Foundation
import Testing
@testable import CupThreadFeedback

// Regression suite for issue #32: the subscribe sheet must keep a close
// affordance in every phase and must never reach the unsubscribe endpoint,
// so macOS/tvOS/visionOS users (no swipe-to-dismiss) can always leave the
// sheet in one tap without destroying their subscription. Issue #273 adds
// the `.managePending` phase for double-opt-in subscriptions whose emailed
// confirmation is still outstanding.
@Suite("ChangelogSubscribeModel", .serialized)
struct ChangelogSubscribeModelTests {
    static let apiHost = "subscribe-model.example.com"
    static let pendingSince = Date(timeIntervalSince1970: 1_760_000_000)

    private func makeModel(in phase: ChangelogSubscribePhase) -> ChangelogSubscribeModel {
        switch phase {
        case .form:
            return ChangelogSubscribeModel(record: nil)
        case .manage:
            return ChangelogSubscribeModel(
                record: ChangelogSubscriptionRecord(email: "user@example.com", state: .confirmed)
            )
        case .managePending:
            return ChangelogSubscribeModel(
                record: ChangelogSubscriptionRecord(
                    email: "user@example.com", state: .pending(since: Self.pendingSince)
                )
            )
        case .subscribed:
            var model = ChangelogSubscribeModel(record: nil)
            model.didSubscribe()
            return model
        }
    }

    // MARK: - Toolbar decisions

    @Test func everyPhaseShowsACloseAffordance() {
        for phase in [ChangelogSubscribePhase.form, .subscribed, .manage, .managePending] {
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
        #expect(makeModel(in: .managePending).primaryAction == .close)
    }

    @Test func subscribedAndManageCloseWithoutSideEffects() {
        for phase in [ChangelogSubscribePhase.subscribed, .manage, .managePending] {
            let model = makeModel(in: phase)
            #expect(model.primaryAction == .close)
            #expect(model.primaryTitle == CupThreadStrings.tr("cupthread.subscribe.done_button"))
            // The close button must never be blocked, even when leftover
            // form state (or none) would fail email validation — an in-flight
            // resend blocks only the resend button, not the close affordance.
            #expect(!model.isPrimaryDisabled)
        }

        var resending = makeModel(in: .managePending)
        resending.isResending = true
        #expect(resending.primaryAction == .close)
        #expect(!resending.isPrimaryDisabled)
    }

    // MARK: - Pending manage phase (issue #273)

    @Test func pendingRecordOpensPendingManagePhaseWithResendAction() {
        let model = makeModel(in: .managePending)
        #expect(model.phase == .managePending)
        #expect(model.rememberedEmail == "user@example.com")
        #expect(model.showsResendConfirmation)
        #expect(!model.isResending)
    }

    @Test func confirmedRecordOpensPlainManagePhaseWithoutResendAction() {
        let model = makeModel(in: .manage)
        #expect(model.phase == .manage)
        #expect(model.rememberedEmail == "user@example.com")
        #expect(!model.showsResendConfirmation)
    }

    @Test func bareEmailInitStillTreatsRememberedAddressAsConfirmed() {
        let model = ChangelogSubscribeModel(subscribedEmail: "user@example.com")
        #expect(model.phase == .manage)
        #expect(!model.showsResendConfirmation)
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

    @Test func startNewEmailEntryFromPendingManageReturnsToBlankForm() {
        var model = makeModel(in: .managePending)
        model.isResending = true

        model.startNewEmailEntry()

        #expect(model.phase == .form)
        #expect(model.email.isEmpty)
        #expect(!model.isWorking)
        #expect(!model.isResending)
        #expect(model.primaryAction == .subscribe)
    }

    @Test func initialPhaseRecordSelection() {
        #expect(ChangelogSubscribeModel.initialPhase(record: nil) == .form)
        #expect(
            ChangelogSubscribeModel.initialPhase(
                record: ChangelogSubscriptionRecord(email: "user@example.com", state: .confirmed)
            ) == .manage
        )
        #expect(
            ChangelogSubscribeModel.initialPhase(
                record: ChangelogSubscriptionRecord(
                    email: "user@example.com", state: .pending(since: Self.pendingSince)
                )
            ) == .managePending
        )
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

    /// Regression suite for issue #281: the shape check previously let
    /// multiple-`@` addresses and empty/trailing-dot domain labels through to
    /// the subscribe endpoint, where they were guaranteed to fail with a
    /// generic 400. Every entry here must fail the shape check *and* keep
    /// the form's primary button disabled.
    @Test func emailValidationRejectsMalformedShapes() {
        var model = makeModel(in: .form)

        let malformed = [
            "user@@gmail.com",   // multiple @ signs
            "a@b@c.com",         // multiple @ signs
            "user@.",            // empty domain after the @
            "user@.com",         // empty leading domain label
            "user@gmail.",       // trailing-dot domain
            "user@a..b",         // doubled dot inside the domain
            "@example.com",      // missing local part
            "user@",             // missing domain
            "user@example .com", // embedded whitespace
            "us er@example.com", // embedded whitespace
            "user@example",      // dotless single-label domain (#283)
            "user@localhost",    // dotless single-label domain (#283)
            ""                  // empty
        ]
        for email in malformed {
            model.email = email
            #expect(!model.isValidEmail, "\(email) must fail the shape check")
            #expect(model.isPrimaryDisabled, "\(email) must not be submittable from the form phase")
        }
    }

    /// The check stays shape-only and shared with the feedback composer's
    /// warn-only hint (#283): real multi-label domains pass, including
    /// local-part tags and deep subdomains the server remains authoritative
    /// over.
    @Test func emailValidationAcceptsPlausibleShapes() {
        var model = makeModel(in: .form)

        let plausible = [
            "user@example.com",
            "user.name+tag@sub.example.co"
        ]
        for email in plausible {
            model.email = email
            #expect(model.isValidEmail, "\(email) is shape-plausible and must pass")
            #expect(!model.isPrimaryDisabled, "\(email) must be submittable from the form phase")
        }
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

    /// The pending manage phase's resend action re-POSTs the remembered
    /// address to the subscribe endpoint (issue #273) — the server re-sends
    /// the confirmation email, its 15-minute cooldown suppressing duplicates.
    @Test func resendConfirmationRepostsRememberedAddressAndKeepsPhase() async throws {
        let recorder = RequestRecorder()
        let lastRequest = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            recorder.append(request.url?.path ?? "")
            lastRequest.value = request
            return (makeHTTPResponse(status: 201), try encodeJSON(["subscribed": true]))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.apiHost, nil) }

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!)
        let model = makeModel(in: .managePending)

        // Drives exactly what the view's resend action performs.
        #expect(model.showsResendConfirmation)
        _ = try await client.subscribeToChangelog(email: model.rememberedEmail, userToken: "user-token")

        let paths = recorder.snapshot()
        #expect(
            paths == ["/api/v1/public/apps/app_testkey123456/changelog/subscribe"],
            "Resending must re-call the subscribe endpoint with the remembered address"
        )
        let request = try #require(lastRequest.value)
        let body = try #require(bodyData(from: request))
        let payload = try #require(parseJSONDict(body))
        #expect(payload["email"] as? String == "user@example.com")

        // The resend never models a phase change or an unsubscribe detour.
        #expect(model.phase == .managePending)
        #expect(!paths.contains { $0.contains("unsubscribe") })
    }

    /// A failed resend surfaces through the sheet's error banner path (the
    /// same `FriendlyError.message(for:)` mapping the form uses) and leaves
    /// the pending phase intact so the user can retry or switch addresses.
    @Test func failedResendMapsToFriendlyMessageAndKeepsPendingPhase() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 500), try encodeJSON(["error": "boom"]))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.apiHost, nil) }

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!)
        let model = makeModel(in: .managePending)

        do {
            _ = try await client.subscribeToChangelog(email: model.rememberedEmail, userToken: "user-token")
            Issue.record("The 500 response must throw")
        } catch {
            let bannerMessage = FriendlyError.message(for: error)
            #expect(!bannerMessage.isEmpty)
            #expect(bannerMessage != "boom", "Raw server text must not reach the banner")
        }

        #expect(model.phase == .managePending, "A failed resend must keep the pending manage phase")
        #expect(model.showsResendConfirmation)
    }

    /// The view persists `.pending` after a successful subscribe (issue #273),
    /// so the next sheet opening starts in the pending manage phase — not in
    /// the confirmed manage view that claims the subscription is active.
    @Test func subscribeSuccessPersistsPendingRecordSoSheetReopensPending() async throws {
        let suiteName = "test.subscribe_pending_reopen.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // A per-run app key keeps the real-Keychain write off a fixed account,
        // so reruns cannot observe a previous run's leftover record.
        let store = ChangelogSubscriptionStore(
            appKey: "app_pending_reopen_\(UUID().uuidString)",
            userDefaults: defaults
        )
        defer { store.clear() }

        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 201), try encodeJSON(["subscribed": true]))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.apiHost, nil) }

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!)
        var model = ChangelogSubscribeModel(record: store.subscriptionRecord())
        #expect(model.phase == .form, "A fresh store must open the blank form")

        model.email = "user@example.com"
        guard case .subscribe = model.primaryAction else {
            Issue.record("Form phase must model .subscribe")
            return
        }
        _ = try await client.subscribeToChangelog(email: model.trimmedEmail, userToken: "user-token")
        // Drives exactly what ChangelogSubscribeView.subscribe() persists.
        store.persist(
            record: ChangelogSubscriptionRecord(email: model.trimmedEmail, state: .pending(since: .now))
        )

        let reopened = ChangelogSubscribeModel(record: store.subscriptionRecord())
        #expect(reopened.phase == .managePending, "A pending record must reopen the pending manage phase")
        #expect(reopened.rememberedEmail == "user@example.com")
        #expect(reopened.showsResendConfirmation)
        #expect(reopened.primaryAction == .close)

        // "Use a Different Email" stays the escape hatch to the blank form.
        var escaped = reopened
        escaped.startNewEmailEntry()
        #expect(escaped.phase == .form)
    }
}
