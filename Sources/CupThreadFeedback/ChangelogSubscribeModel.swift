import Foundation

/// Presentation phases of the changelog subscribe sheet.
enum ChangelogSubscribePhase: Equatable, Sendable {
    /// Blank email form; shown when no subscription is remembered.
    case form
    /// Subscription just recorded; awaiting the emailed double opt-in.
    case subscribed
    /// Returning user with a confirmed subscription; shows the address.
    case manage
    /// Returning user whose subscription is still awaiting the emailed
    /// confirmation (issue #273): offers resending the confirmation email
    /// and switching to a different address, with honest pending copy.
    case managePending
}

/// What the sheet's primary (confirmation) button does in the current phase.
enum ChangelogSubscribeAction: Equatable, Sendable {
    /// POST the entered email to the subscribe endpoint.
    case subscribe
    /// Dismiss the sheet without any network side effect.
    case close
}

/// Pure state machine behind `ChangelogSubscribeView`.
///
/// Owns the phase/toolbar decisions the sheet renders so they can be unit
/// tested without hosting SwiftUI. The guarantees pinned here (and tested)
/// are that **every** phase exposes a close affordance and that no modeled
/// action can reach the unsubscribe endpoint — unsubscribing happens
/// out-of-band through the emailed link, never through a sheet button. Two
/// actions touch the network: the form's `.subscribe` and, in the pending
/// manage phase, the secondary resend-confirmation request.
struct ChangelogSubscribeModel: Equatable, Sendable {
    private(set) var phase: ChangelogSubscribePhase
    var email = ""
    let rememberedEmail: String
    var isWorking = false
    /// True while the resend-confirmation request is in flight; blocks only
    /// the resend button, never the close affordance.
    var isResending = false

    /// Opens in a manage phase when a subscription is remembered for this
    /// app key — `.managePending` while the emailed confirmation is
    /// outstanding, `.manage` once confirmed — otherwise on the blank form.
    init(record: ChangelogSubscriptionRecord?) {
        guard let record else {
            phase = .form
            rememberedEmail = ""
            return
        }
        rememberedEmail = record.email
        phase = record.state.isPending ? .managePending : .manage
    }

    /// Convenience for callers that only know the remembered address: it is
    /// treated as a confirmed subscription (the pre-#273 storage shape).
    init(subscribedEmail: String?) {
        self.init(
            record: subscribedEmail.map {
                ChangelogSubscriptionRecord(email: $0, state: .confirmed)
            }
        )
    }

    /// The phase a sheet should open in for the given remembered address.
    static func initialPhase(subscribedEmail: String?) -> ChangelogSubscribePhase {
        ChangelogSubscribeModel(subscribedEmail: subscribedEmail).phase
    }

    /// The phase a sheet should open in for the given remembered record.
    static func initialPhase(record: ChangelogSubscriptionRecord?) -> ChangelogSubscribePhase {
        ChangelogSubscribeModel(record: record).phase
    }

    var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lightweight shape check — full validation happens server-side.
    ///
    /// Delegates to the shared `EmailShape` helper (#283), which also rejects
    /// the multiple-`@`, empty-label, and trailing-dot shapes #281 documented.
    var isValidEmail: Bool {
        EmailShape.isPlausible(email)
    }

    /// A dismissal affordance is rendered in **every** phase, so users on
    /// platforms without swipe-to-dismiss (macOS, tvOS, visionOS) can always
    /// close the sheet in one tap.
    var showsClose: Bool {
        true
    }

    /// Whether the current phase offers the secondary "Resend Confirmation
    /// Email" action: only the pending manage phase.
    var showsResendConfirmation: Bool {
        phase == .managePending
    }

    var primaryTitle: String {
        switch phase {
        case .form:
            return isWorking
                ? CupThreadStrings.tr("cupthread.subscribe.subscribing_button")
                : CupThreadStrings.tr("cupthread.subscribe.subscribe_button")
        case .subscribed, .manage, .managePending:
            return CupThreadStrings.tr("cupthread.subscribe.done_button")
        }
    }

    /// Only the blank form's primary button performs work; in `.subscribed`,
    /// `.manage`, and `.managePending` it is a plain close action.
    var primaryAction: ChangelogSubscribeAction {
        phase == .form ? .subscribe : .close
    }

    var isPrimaryDisabled: Bool {
        isWorking || (phase == .form && !isValidEmail)
    }

    /// Transition applied after the subscribe request succeeds.
    mutating func didSubscribe() {
        phase = .subscribed
        isWorking = false
    }

    /// Transition for "Use a Different Email" from either manage phase.
    mutating func startNewEmailEntry() {
        email = ""
        isWorking = false
        isResending = false
        phase = .form
    }
}
