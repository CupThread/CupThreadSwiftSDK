import Foundation

/// Presentation phases of the changelog subscribe sheet.
enum ChangelogSubscribePhase: Equatable, Sendable {
    /// Blank email form; shown when no subscription is remembered.
    case form
    /// Subscription just recorded; awaiting the emailed double opt-in.
    case subscribed
    /// Returning user; shows the remembered subscribed address.
    case manage
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
/// tested without hosting SwiftUI. The guarantee pinned here (and tested) is
/// that **every** phase exposes a close affordance and that the only action
/// in the entire machine capable of touching the network is `.subscribe` —
/// unsubscribing happens out-of-band through the emailed link, never through
/// a sheet button.
struct ChangelogSubscribeModel: Equatable, Sendable {
    private(set) var phase: ChangelogSubscribePhase
    var email = ""
    let rememberedEmail: String
    var isWorking = false

    /// Opens in `.manage` when a subscription is remembered for this app key,
    /// otherwise on the blank email form.
    init(subscribedEmail: String?) {
        phase = subscribedEmail == nil ? .form : .manage
        rememberedEmail = subscribedEmail ?? ""
    }

    /// The phase a sheet should open in for the given remembered state.
    static func initialPhase(subscribedEmail: String?) -> ChangelogSubscribePhase {
        subscribedEmail == nil ? .form : .manage
    }

    var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lightweight shape check — full validation happens server-side.
    var isValidEmail: Bool {
        let trimmed = trimmedEmail
        guard let at = trimmed.firstIndex(of: "@"),
              at != trimmed.startIndex,
              at != trimmed.index(before: trimmed.endIndex),
              trimmed.suffix(from: at).contains(".") else {
            return false
        }
        return !trimmed.contains(where: \.isWhitespace)
    }

    /// A dismissal affordance is rendered in **every** phase, so users on
    /// platforms without swipe-to-dismiss (macOS, tvOS, visionOS) can always
    /// close the sheet in one tap.
    var showsClose: Bool {
        true
    }

    var primaryTitle: String {
        switch phase {
        case .form:
            return isWorking ? "Subscribing…" : "Subscribe"
        case .subscribed, .manage:
            return "Done"
        }
    }

    /// Only the blank form's primary button performs work; in `.subscribed`
    /// and `.manage` it is a plain close action.
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

    /// Transition for "Use a Different Email" from the manage phase.
    mutating func startNewEmailEntry() {
        email = ""
        isWorking = false
        phase = .form
    }
}
