import SwiftUI

/// What should happen when the user tries to leave a compose surface.
enum ComposerDismissalDecision: Equatable {
    /// Nothing user-typed would be lost; leaving can proceed silently.
    case dismiss
    /// User-typed content is present (or a submission is in flight);
    /// leaving must go through an explicit, confirmed discard.
    case confirmDiscard

    /// Decides how a compose surface should react to a leave attempt.
    ///
    /// - Parameters:
    ///   - hasContent: Whether the draft holds user-typed content or attachments.
    ///   - isSubmitting: Whether a submission is currently in flight.
    static func resolve(hasContent: Bool, isSubmitting: Bool) -> ComposerDismissalDecision {
        (hasContent || isSubmitting) ? .confirmDiscard : .dismiss
    }
}

/// Guards a compose sheet against accidental dismissal: interactive
/// dismissal (swipe-down on iOS, Escape on macOS) is blocked while the draft
/// holds content, and the leading Cancel action either dismisses right away
/// (empty draft) or asks for confirmation first, so a careless gesture can
/// never silently destroy user input.
struct ComposerDismissGuardModifier: ViewModifier {
    let hasContent: Bool
    let isSubmitting: Bool
    /// Localization key of the confirmation dialog's title.
    let discardTitleKey: String

    @Environment(\.dismiss) private var dismiss
    @State private var showsDiscardConfirmation = false

    func body(content: Content) -> some View {
        content
            .interactiveDismissDisabled(hasContent || isSubmitting)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(CupThreadStrings.tr("cupthread.common.cancel")) {
                        if ComposerDismissalDecision.resolve(hasContent: hasContent, isSubmitting: isSubmitting) == .dismiss {
                            dismiss()
                        } else {
                            showsDiscardConfirmation = true
                        }
                    }
                }
            }
            .confirmationDialog(
                CupThreadStrings.tr(discardTitleKey),
                isPresented: $showsDiscardConfirmation,
                titleVisibility: .visible
            ) {
                Button(CupThreadStrings.tr("cupthread.common.discard"), role: .destructive) {
                    dismiss()
                }
                Button(CupThreadStrings.tr("cupthread.common.keep_editing"), role: .cancel) {}
            }
    }
}

extension View {
    /// Applies the shared accidental-dismissal guard to a compose surface.
    ///
    /// - Parameters:
    ///   - hasContent: Whether the draft holds user-typed content or attachments.
    ///   - isSubmitting: Whether a submission is currently in flight.
    ///   - discardTitleKey: Localization key of the discard confirmation title.
    func composerDismissGuard(
        hasContent: Bool,
        isSubmitting: Bool,
        discardTitleKey: String
    ) -> some View {
        modifier(
            ComposerDismissGuardModifier(
                hasContent: hasContent,
                isSubmitting: isSubmitting,
                discardTitleKey: discardTitleKey
            )
        )
    }
}
