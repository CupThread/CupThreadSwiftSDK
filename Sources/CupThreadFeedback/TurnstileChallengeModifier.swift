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
/// presented challenge here and lets the presented content's `onDisappear`
/// run its `cancel` closure. The button paths resolve the registration first,
/// which turns the dismissal that follows into a no-op and keeps `cancel` to
/// one invocation.
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
    mutating func resolve(_ challenge: PendingTurnstileChallenge) {
        guard outstanding?.id == challenge.id else { return }
        outstanding = nil
    }

    /// The presented content went away. Settles only the challenge whose
    /// sheet actually disappeared: a retry can publish the next challenge
    /// before the previous sheet's lifecycle callback runs, and that late
    /// callback must not cancel the newer attempt.
    mutating func settleOnDismiss(for id: PendingTurnstileChallenge.ID) -> PendingTurnstileChallenge? {
        guard outstanding?.id == id else { return nil }
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
        content.sheet(item: $pending) { challenge in
            TurnstileChallengeSheet(
                challengeURL: challenge.presentation.url,
                onVerified: { token in
                    settlement.resolve(challenge)
                    pending = nil
                    challenge.resume(token)
                },
                onCancel: {
                    settlement.resolve(challenge)
                    pending = nil
                    challenge.cancel()
                }
            )
            .onAppear {
                settlement.register(challenge)
            }
            // The presented content is the identity-scoped dismissal hook:
            // `sheet(item:onDismiss:)` has no item parameter, so a late
            // callback could otherwise cancel a challenge the retry published
            // in the meantime. Settle only the challenge this sheet owns.
            .onDisappear {
                settlement.settleOnDismiss(for: challenge.id)?.cancel()
            }
        }
        #else
        content
        #endif
    }
}
