import SwiftUI
#if canImport(PhotosUI) && !os(tvOS)
import PhotosUI
#endif

// Support views for FeedbackComposerView, kept out of the composer file to
// stay under the repo's file-length budget.

#if canImport(PhotosUI) && !os(tvOS)
struct PhotosPickerLabelView: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo")
            Text(CupThreadStrings.tr("cupthread.feedback.add_attachment"))
        }
    }
}
#endif

// MARK: - Success state

struct FeedbackSentView: View {
    let warning: String?
    let onSendMore: () -> Void

    @State private var showCheckmark = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 24)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
                .scaleEffect(showCheckmark ? 1 : 0.4)
                .opacity(showCheckmark ? 1 : 0)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(CupThreadStrings.tr("cupthread.feedback.thanks_title"))
                    .font(.title2.weight(.semibold))
                Text(CupThreadStrings.tr("cupthread.feedback.thanks_subtitle"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let warning {
                Text(warning)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
            }

            Button(CupThreadStrings.tr("cupthread.feedback.send_more")) {
                onSendMore()
            }
            .buttonStyle(.bordered)
            .padding(.top, 8)

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.6).delay(0.1)) {
                showCheckmark = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(CupThreadStrings.tr("cupthread.feedback.accessibility_sent"))
    }
}
