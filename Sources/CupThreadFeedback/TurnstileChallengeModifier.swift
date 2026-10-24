import SwiftUI

// MARK: - Pending challenge presentation (#53 Phase 2)

/// A human-verification challenge the SDK is presenting, plus the action that
/// resumes the rejected call once the widget mints a token.
struct PendingTurnstileChallenge: Identifiable {
    let id = UUID()
    let presentation: TurnstileChallengePresentation
    /// Resumes the rejected call with the freshly minted single-use token.
    let resume: @MainActor (String) -> Void
    /// Restores the surface's localized turnstile guidance when the user
    /// dismisses the sheet without verifying — the call stays unsent.
    let cancel: @MainActor () -> Void
}

/// Settles a presented challenge exactly once across the sheet's terminal
/// paths: verified, explicit Cancel, and a dismissal that ran neither (#539).
///
/// SwiftUI's `sheet(item:)` nils the binding on an interactive swipe-down
/// without invoking the sheet's buttons, so the modifier registers the
/// presented challenge here and lets `onDismiss` run its `cancel` closure.
/// The button paths resolve the registration first, which turns the
/// dismissal that follows into a no-op and keeps `cancel` to one invocation.
struct TurnstileChallengeSettlement {
    private var outstanding: PendingTurnstileChallenge?

    /// Records the challenge the sheet is currently presenting.
    ///
    /// Registration never replaces an active challenge: the creator must
    /// refuse to present a second challenge while one is pending, or the
    /// first challenge's `cancel` closure would be dropped unrun.
    mutating func register(_ challenge: PendingTurnstileChallenge) {
        guard outstanding == nil else { return }
        outstanding = challenge
    }

    /// Marks the challenge as answered by an explicit sheet action.
    mutating func resolve() {
        outstanding = nil
    }

    /// Returns the challenge that still needs settling, then clears it.
    mutating func settleOnDismiss() -> PendingTurnstileChallenge? {
        defer { outstanding = nil }
        return outstanding
    }
}

extension View {
    /// Presents ``TurnstileChallengeSheet`` for a pending rejection.
    ///
    /// A no-op where WebKit is unavailable (tvOS): ``FeedbackClient`` never
    /// resolves a presentation there, so the binding stays `nil` and the
    /// surface keeps its localized `turnstileRequired` banner.
    func turnstileChallengeSheet(_ pending: Binding<PendingTurnstileChallenge?>) -> some View {
        modifier(TurnstileChallengeSheetModifier(pending: pending))
    }
}

private struct TurnstileChallengeSheetModifier: ViewModifier {
    @Binding var pending: PendingTurnstileChallenge?
    @State private var settlement = TurnstileChallengeSettlement()

    func body(content: Content) -> some View {
        #if canImport(WebKit) && !os(tvOS)
        content.sheet(item: $pending, onDismiss: settleOnDismiss) { challenge in
            TurnstileChallengeSheet(
                challengeURL: challenge.presentation.url,
                onVerified: { token in
                    settlement.resolve()
                    pending = nil
                    challenge.resume(token)
                },
                onCancel: {
                    settlement.resolve()
                    pending = nil
                    challenge.cancel()
                }
            )
            .onAppear {
                settlement.register(challenge)
            }
        }
        #else
        content
        #endif
    }

    /// The sheet went away without a decision — an interactive swipe-down
    /// (if the host re-enabled it), a parent teardown, or a programmatic
    /// dismissal. The pending work must still be settled or the composer is
    /// left non-submittable with an orphaned spooled photo (#539).
    private func settleOnDismiss() {
        settlement.settleOnDismiss()?.cancel()
    }
}
