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
    @State private var attachmentState: FeedbackAttachmentStateMachine
    @State private var errorMessage: String?
    @State private var result: FeedbackSubmissionResult?
    @State private var uploadTask: Task<Void, Never>?

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
    ///   - maxAttachmentBytes: Optional client-side upload size cap in bytes;
    ///     falls back to ``PhotoAttachmentHelper/defaultMaxAttachmentBytes`` (20 MB)
    ///     or the fetched ``PublicAppConfig/maxAttachmentBytes``.
    ///   - onSubmit: Called with the server's receipt after a successful
    ///     submission — use it to log, show a toast, or deep-link elsewhere.
    public init(
        client: FeedbackClient,
        initialDraft: FeedbackDraft? = nil,
        userToken: String? = nil,
        maxAttachmentBytes: Int? = nil,
        onSubmit: @escaping (FeedbackSubmissionResult) -> Void = { _ in }
    ) {
        self.client = client
        self.userToken = userToken
        self.onSubmit = onSubmit
        let limit = maxAttachmentBytes ?? PhotoAttachmentHelper.defaultMaxAttachmentBytes
        _attachmentState = State(initialValue: FeedbackAttachmentStateMachine(maxAttachmentBytes: limit))
        _draft = State(initialValue: initialDraft ?? FeedbackDraft.autofilled(platform: client.configuration.defaultPlatform))
    }

    public var body: some View {
        Group {
            if let result {
                FeedbackSentView(warning: result.warning) {
                    withAnimation(.snappy(duration: 0.3)) {
                        self.result = nil
                        self.resetForm()
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
            uploadTask?.cancel()
            let uploadId = attachmentState.startUpload()
            uploadTask = Task {
                await uploadPhotoItem(newItem, uploadId: uploadId)
                if !Task.isCancelled && attachmentState.activeUploadId == uploadId {
                    selectedPhotoItem = nil
                }
            }
        }
        #endif
        .task {
            if let config = try? await client.fetchAppConfig() {
                attachmentState.maxAttachmentBytes = config.maxAttachmentBytes
            }
        }
        .onDisappear {
            cancelUpload()
        }
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
            if attachmentState.isUploading {
                uploadingAttachmentRow
            } else if draft.attachments.count < 5 {
                PhotosPicker(
                    selection: $selectedPhotoItem,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    PhotosPickerLabelView()
                }
            }
            #endif

            if let attachmentErrorMessage = attachmentState.currentErrorMessage {
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
                attachmentState.removeAttachment(id: attachment.id, draft: &draft)
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
    private var uploadingAttachmentRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(CupThreadStrings.tr("cupthread.feedback.uploading_attachment"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                cancelUpload()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(CupThreadStrings.tr("cupthread.feedback.remove_attachment"))
        }
    }

    @MainActor
    private func uploadPhotoItem(_ item: PhotosPickerItem, uploadId: UUID) async {
        attachmentState.clearError()

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                guard !Task.isCancelled, attachmentState.activeUploadId == uploadId else { return }
                _ = attachmentState.uploadFailed(
                    id: uploadId,
                    error: NSError(domain: "CupThread", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not load photo data"])
                )
                return
            }

            try Task.checkCancellation()
            guard attachmentState.activeUploadId == uploadId else { return }

            try PhotoAttachmentHelper.validateAttachmentSize(
                data.count,
                limit: attachmentState.maxAttachmentBytes
            )

            try Task.checkCancellation()
            guard attachmentState.activeUploadId == uploadId else { return }

            let metadata = PhotoAttachmentHelper.detectImageFormat(
                from: data,
                contentTypes: item.supportedContentTypes
            )
            let filename = PhotoAttachmentHelper.makeFilename(
                fileExtension: metadata.fileExtension,
                id: uploadId
            )

            let uploaded = try await client.uploadAttachment(
                data: data,
                filename: filename,
                mimeType: metadata.mimeType
            )

            guard !Task.isCancelled, attachmentState.activeUploadId == uploadId else { return }
            _ = attachmentState.uploadSucceeded(id: uploadId, attachment: uploaded, draft: &draft)
        } catch is CancellationError {
            if attachmentState.activeUploadId == uploadId {
                attachmentState.cancelUpload()
            }
        } catch {
            guard !Task.isCancelled, attachmentState.activeUploadId == uploadId else { return }
            _ = attachmentState.uploadFailed(id: uploadId, error: error)
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
        attachmentState.canSubmit(draft: draft)
    }

    @MainActor
    private func submitDraft() async {
        guard canSubmit && !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        let currentDraft = draft
        let currentClient = client

        do {
            let result = try await currentClient.submit(currentDraft, userToken: userToken)
            onSubmit(result)
            withAnimation(.snappy(duration: 0.3)) {
                self.result = result
                self.resetForm()
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isSubmitting = false
    }

    @MainActor
    private func cancelUpload() {
        uploadTask?.cancel()
        uploadTask = nil
        attachmentState.cancelUpload()
        #if canImport(PhotosUI) && !os(tvOS)
        selectedPhotoItem = nil
        #endif
    }

    @MainActor
    private func resetForm() {
        cancelUpload()
        attachmentState.reset(draft: &draft, defaultPlatform: client.configuration.defaultPlatform)
        errorMessage = nil
    }
}

#if canImport(PhotosUI) && !os(tvOS)
private struct PhotosPickerLabelView: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo")
            Text(CupThreadStrings.tr("cupthread.feedback.add_attachment"))
        }
    }
}
#endif

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
