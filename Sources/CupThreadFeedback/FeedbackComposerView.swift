import SwiftUI
#if canImport(PhotosUI) && !os(tvOS)
import PhotosUI
#endif

/// Structured feedback form with a built-in success state.
///
/// The draft is pre-filled with the host app's platform and version. Contact
/// fields are optional; environment details are sent automatically and shown
/// to the user before submitting. On success the view shows an acknowledgment
/// (and calls `onSubmit` for host apps that need the result).
public struct FeedbackComposerView: View {
    public let client: FeedbackClient
    public let userToken: String?
    public let onSubmit: (FeedbackSubmissionResult) -> Void

    @State private var draft: FeedbackDraft
    @State private var isSubmitting = false
    @State private var isUploadingAttachment = false
    @State private var attachmentErrorMessage: String?
    @State private var errorMessage: String?
    @State private var result: FeedbackSubmissionResult?

    #if canImport(PhotosUI) && !os(tvOS)
    @State private var selectedPhotoItem: PhotosPickerItem?
    #endif

    /// Creates the feedback form.
    ///
    /// The view enforces a minimum length (title ≥ 3, description ≥ 5
    /// characters) before enabling the send button, shows an inline error
    /// banner on failure, and swaps to a success screen on completion.
    ///
    /// Wrap your hierarchy in ``CupThreadTheme`` or present the view through
    /// one of the SDK containers so console feature flags and theming apply.
    /// - Parameters:
    ///   - client: The shared ``FeedbackClient``.
    ///   - initialDraft: Draft the form starts from. Defaults to
    ///     ``FeedbackDraft/autofilled(platform:)`` using the client's
    ///     ``FeedbackClientConfiguration/defaultPlatform``.
    ///   - userToken: Optional anonymous token; when given it is sent as
    ///     `X-User-Token` so submissions link to the end-user identity.
    ///   - onSubmit: Called with the server's receipt after a successful
    ///     submission — use it to log, show a toast, or deep-link elsewhere.
    public init(
        client: FeedbackClient,
        initialDraft: FeedbackDraft? = nil,
        userToken: String? = nil,
        onSubmit: @escaping (FeedbackSubmissionResult) -> Void = { _ in }
    ) {
        self.client = client
        self.userToken = userToken
        self.onSubmit = onSubmit
        _draft = State(initialValue: initialDraft ?? FeedbackDraft.autofilled(platform: client.configuration.defaultPlatform))
    }

    public var body: some View {
        Group {
            if let result {
                FeedbackSentView(warning: result.warning) {
                    withAnimation(.snappy(duration: 0.3)) {
                        self.result = nil
                    }
                }
            } else {
                composer
            }
        }
        .navigationTitle(CupThreadStrings.tr("cupthread.feedback.title"))
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if canImport(PhotosUI) && !os(tvOS)
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                await uploadPhotoItem(newItem)
                selectedPhotoItem = nil
            }
        }
        #endif
        .sdkSurface(client: client, feature: .feedback)
    }

    private var composer: some View {
        VStack(spacing: 0) {
            Form {
                contentSection
                contactSection
                attachmentsSection
            }
            // Unavailable on visionOS (and meaningless on macOS/tvOS).
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif

            if let errorMessage {
                ErrorBanner(message: errorMessage)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }

            submitBar
        }
    }

    private var contentSection: some View {
        Section {
            TextField(CupThreadStrings.tr("cupthread.feedback.title_label"), text: $draft.title, prompt: Text(CupThreadStrings.tr("cupthread.feedback.short_summary")))
                #if canImport(UIKit)
                .submitLabel(.next)
                #endif
            TextField(CupThreadStrings.tr("cupthread.feedback.description_label"), text: $draft.description, axis: .vertical)
                .lineLimit(6...12)
                .padding(.top, 2)
                #if canImport(UIKit)
                .submitLabel(.send)
                #endif
        } header: {
            Text(CupThreadStrings.tr("cupthread.feedback.section_feedback"))
        } footer: {
            Text(CupThreadStrings.tr("cupthread.feedback.section_feedback_footer"))
        }
    }

    private var contactSection: some View {
        Section {
            TextField(CupThreadStrings.tr("cupthread.feedback.name_label"), text: $draft.reporterName)
            TextField(CupThreadStrings.tr("cupthread.feedback.email_label"), text: $draft.reporterEmail)
                #if canImport(UIKit)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                #endif
        } header: {
            Text(CupThreadStrings.tr("cupthread.feedback.section_contact"))
        } footer: {
            Text(CupThreadStrings.tr("cupthread.feedback.section_contact_footer"))
        }
    }

    private var attachmentsSection: some View {
        Section {
            ForEach(draft.attachments) { attachment in
                attachmentRow(attachment)
            }

            #if canImport(PhotosUI) && !os(tvOS)
            if draft.attachments.count < 5 {
                PhotosPicker(
                    selection: $selectedPhotoItem,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    photosPickerLabel
                }
                .disabled(isUploadingAttachment)
            }
            #endif

            if let attachmentErrorMessage {
                ErrorBanner(message: attachmentErrorMessage)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
            }
        } header: {
            Text(CupThreadStrings.tr("cupthread.feedback.section_attachments"))
        } footer: {
            Text(CupThreadStrings.tr("cupthread.feedback.section_attachments_footer"))
        }
    }

    private func attachmentRow(_ attachment: FeedbackAttachment) -> some View {
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
                draft.attachments.removeAll { $0.id == attachment.id }
            } label: {
                Image(systemName: "trash")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(CupThreadStrings.tr("cupthread.feedback.remove_attachment"))
        }
    }

    #if canImport(PhotosUI) && !os(tvOS)
    @MainActor @ViewBuilder
    private var photosPickerLabel: some View {
        HStack(spacing: 8) {
            if isUploadingAttachment {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "photo")
            }
            Text(
                isUploadingAttachment
                    ? CupThreadStrings.tr("cupthread.feedback.uploading_attachment")
                    : CupThreadStrings.tr("cupthread.feedback.add_attachment")
            )
        }
    }

    @MainActor
    private func uploadPhotoItem(_ item: PhotosPickerItem) async {
        isUploadingAttachment = true
        attachmentErrorMessage = nil
        defer { isUploadingAttachment = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                attachmentErrorMessage = "Could not load photo data"
                return
            }
            let filename = "screenshot_\(Int(Date().timeIntervalSince1970)).jpg"
            let uploaded = try await client.uploadAttachment(data: data, filename: filename, mimeType: "image/jpeg")
            draft.attachments.append(uploaded)
        } catch {
            attachmentErrorMessage = error.localizedDescription
        }
    }
    #endif

    private var submitBar: some View {
        Button {
            Task { await submitDraft() }
        } label: {
            HStack(spacing: 8) {
                if isSubmitting {
                    ProgressView()
                }
                Text(isSubmitting ? CupThreadStrings.tr("cupthread.feedback.sending_button") : CupThreadStrings.tr("cupthread.feedback.send_button"))
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

    // MARK: Submit

    private var canSubmit: Bool {
        draft.title.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 &&
        draft.description.trimmingCharacters(in: .whitespacesAndNewlines).count >= 5
    }

    @MainActor
    private func submitDraft() async {
        isSubmitting = true
        errorMessage = nil
        let currentDraft = draft
        let currentClient = client

        do {
            let result = try await currentClient.submit(currentDraft, userToken: userToken)
            onSubmit(result)
            withAnimation(.snappy(duration: 0.3)) {
                self.result = result
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isSubmitting = false
    }
}

// MARK: - Success state

private struct FeedbackSentView: View {
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
