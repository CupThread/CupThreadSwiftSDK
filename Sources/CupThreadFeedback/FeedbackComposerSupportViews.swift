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
    var onDismiss: (() -> Void)?
    let onSendMore: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showCheckmark = false

    init(
        warning: String? = nil,
        onDismiss: (() -> Void)? = nil,
        onSendMore: @escaping () -> Void
    ) {
        self.warning = warning
        self.onDismiss = onDismiss
        self.onSendMore = onSendMore
    }

    private func performDismiss() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

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

            VStack(spacing: 12) {
                Button(CupThreadStrings.tr("cupthread.common.done")) {
                    performDismiss()
                }
                .buttonStyle(.borderedProminent)

                Button(CupThreadStrings.tr("cupthread.feedback.send_more")) {
                    onSendMore()
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 8)

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(CupThreadStrings.tr("cupthread.common.done")) {
                    performDismiss()
                }
            }
        }
        .task {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.6).delay(0.1)) {
                showCheckmark = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(CupThreadStrings.tr("cupthread.feedback.accessibility_sent"))
    }
}

// MARK: - Dismissal affordance

/// What dismissal affordance `FeedbackComposerView` exposes to the user.
enum FeedbackComposerDismissalAffordance: Equatable, Sendable {
    /// In sent confirmation state, dismissal is completed via Done.
    case done
    /// When permission is denied, dismissal is an immediate Cancel action.
    case cancel
    /// When actively composing, dismissal is guarded against losing draft content.
    case guardedCancel

    static func resolve(
        result: FeedbackSubmissionResult?,
        denial: SdkSubmissionDenial
    ) -> FeedbackComposerDismissalAffordance {
        if result != nil {
            return .done
        }
        if denial != .none {
            return .cancel
        }
        return .guardedCancel
    }
}

// MARK: - Attachment & Submit views

struct FeedbackAttachmentRowView: View {
    let attachment: FeedbackAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: attachment.kind == .image ? "photo" : "doc")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename ?? attachment.key)
                    .font(.subheadline)
                    .lineLimit(1)
                if let size = attachment.size {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button {
                onRemove()
            } label: {
                Image(systemName: "trash")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(CupThreadStrings.tr("cupthread.feedback.remove_attachment"))
        }
    }
}

#if canImport(PhotosUI) && !os(tvOS)
struct FeedbackUploadingAttachmentRowView: View {
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(CupThreadStrings.tr("cupthread.feedback.uploading_attachment"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(CupThreadStrings.tr("cupthread.feedback.remove_attachment"))
        }
    }
}
#endif

struct FeedbackSubmitBarView: View {
    let isSubmitting: Bool
    let canSubmit: Bool
    let onSubmit: () -> Void

    var body: some View {
        Button {
            onSubmit()
        } label: {
            HStack(spacing: 8) {
                if isSubmitting {
                    ProgressView()
                }
                Text(isSubmitting
                    ? CupThreadStrings.tr("cupthread.feedback.sending_button")
                    : CupThreadStrings.tr("cupthread.feedback.send_button"))
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            // 26pt label + 14pt borderedProminent inset = 40pt button
            .frame(height: 26)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isSubmitting || !canSubmit)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        #if !os(tvOS)
        .background(.bar)
        #endif
    }
}
