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

    func body(content: Content) -> some View {
        #if canImport(WebKit) && !os(tvOS)
        content.sheet(item: $pending) { challenge in
            TurnstileChallengeSheet(
                challengeURL: challenge.presentation.url,
                onVerified: { token in
                    pending = nil
                    challenge.resume(token)
                },
                onCancel: {
                    pending = nil
                    challenge.cancel()
                }
            )
        }
        #else
        content
        #endif
    }
}
