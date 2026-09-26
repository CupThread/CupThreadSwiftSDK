import SwiftUI
#if canImport(PhotosUI) && !os(tvOS)
import PhotosUI
#endif

/// Structured feedback form with a built-in success state.
///
/// The draft is pre-filled with the host app's platform, marketing version,
/// and build number. Contact fields are optional; environment details are sent
/// automatically and shown to the user before submitting. Photo attachments
/// selected via the photo picker are stripped of sensitive metadata (EXIF GPS
/// coordinates, camera details, timestamps) before upload by default to
/// protect user privacy. Photo preparation (decoding, metadata stripping,
/// transcoding) runs off the main actor, so the UI stays responsive while
/// even large photos are readied for upload. On success the view shows an
/// acknowledgment (and
/// calls `onSubmit` for host apps that need the result).
///
/// Attachment uploads are independent of the view's lifecycle: transient
/// disappearances never cancel an in-flight upload. Embedding the composer in
/// a `NavigationStack` or a `TabView` tab is safe — pushing a view on top or
/// switching tabs leaves the upload running, and a completed upload is
/// appended to the draft when the user returns. Uploads stop only at explicit
/// points: the cancel button on the uploading row, a superseding photo
/// selection, and the form reset after a successful submit. When the composer
/// is dismissed entirely, an in-flight upload finishes in the background and
/// its result is discarded. Hosts that prefer to stop the transfer on real
/// dismissal can pass a ``FeedbackUploadHandle`` and call
/// ``FeedbackUploadHandle/cancelActiveUpload()`` from the presentation
/// context's `onDismiss` closure.
public struct FeedbackComposerView: View {
    public let client: FeedbackClient
    public let userToken: String?
    public let onSubmit: (FeedbackSubmissionResult) -> Void
    public let stripSensitiveMetadata: Bool
    /// Optional handle for cancelling the in-flight upload from outside the
    /// view, e.g. from a sheet's `onDismiss` closure.
    public let uploadHandle: FeedbackUploadHandle?

    private let config: PublicAppConfig?
    private let onDismiss: (() -> Void)?

    @State private var draft: FeedbackDraft
    @State private var isSubmitting = false
    @State private var attachmentState: FeedbackAttachmentStateMachine
    @State private var errorMessage: String?
    @State private var result: FeedbackSubmissionResult?
    @Environment(\.sdkAppConfig) private var sdkAppConfig
    @Environment(\.dismiss) private var dismiss

    private var activeConfig: PublicAppConfig? {
        config ?? sdkAppConfig
    }

    private var submissionDenial: SdkSubmissionDenial {
        SdkSubmissionDenial.forFeedback(config: activeConfig, platform: draft.platform)
    }

    var dismissalAffordance: FeedbackComposerDismissalAffordance {
        FeedbackComposerDismissalAffordance.resolve(
            result: result,
            denial: submissionDenial
        )
    }

    private func performDismiss() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    #if canImport(PhotosUI) && !os(tvOS)
    @State private var selectionCoordinator = PhotoSelectionUploadCoordinator<PhotosPickerItem>()
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
    ///     When `userToken` is `nil`, anonymous flows fall back to
    ///     the client's app-key-scoped ``UserTokenStore`` when attachments are uploaded and submitted.
    ///   - maxAttachmentBytes: Optional client-side upload size cap in bytes.
    ///     An explicit non-nil value is authoritative and takes precedence over console
    ///     configuration. When `nil`, falls back to the fetched
    ///     ``PublicAppConfig/maxAttachmentBytes`` or
    ///     ``PhotoAttachmentHelper/defaultMaxAttachmentBytes`` (20 MB). Photos
    ///     larger than the limit are automatically downscaled and re-encoded
    ///     as JPEG to fit before upload (see
    ///     ``PhotoAttachmentHelper/downscaledImageData(_:limit:maxDimension:)``).
    ///   - stripSensitiveMetadata: When `true` (the default), photo attachments selected
    ///     via the photo picker are re-encoded to strip GPS coordinates, camera details,
    ///     and sensitive EXIF metadata before upload. Multi-frame animations (such as GIF or
    ///     animated WebP) are preserved intact without flattening to a still image.
    ///     Set to `false` to upload original bytes for formats accepted as-is (PNG, JPEG, WebP, GIF);
    ///     note that HEIC/HEIF and unrecognized formats are always transcoded to JPEG per server media policy.
    ///   - uploadHandle: Optional ``FeedbackUploadHandle`` for cancelling the
    ///     in-flight attachment upload from outside the view — e.g. from a
    ///     sheet's `onDismiss` closure. Uploads are never cancelled by view
    ///     lifecycle events; see ``FeedbackComposerView``.
    ///   - config: Optional ``PublicAppConfig`` override for previewing or testing permissions.
    ///   - initialResult: Optional initial submission result for testing the sent confirmation state.
    ///   - onDismiss: Optional dismissal action callback.
    ///   - onSubmit: Called with the server's receipt after a successful
    ///     submission — use it to log, show a toast, or deep-link elsewhere.
    public init(
        client: FeedbackClient,
        initialDraft: FeedbackDraft? = nil,
        userToken: String? = nil,
        maxAttachmentBytes: Int? = nil,
        stripSensitiveMetadata: Bool = true,
        uploadHandle: FeedbackUploadHandle? = nil,
        config: PublicAppConfig? = nil,
        initialResult: FeedbackSubmissionResult? = nil,
        onDismiss: (() -> Void)? = nil,
        onSubmit: @escaping (FeedbackSubmissionResult) -> Void = { _ in }
    ) {
        self.client = client
        self.userToken = userToken
        self.stripSensitiveMetadata = stripSensitiveMetadata
        self.uploadHandle = uploadHandle
        self.config = config
        self.onDismiss = onDismiss
        self.onSubmit = onSubmit
        _attachmentState = State(initialValue: FeedbackAttachmentStateMachine(maxAttachmentBytes: maxAttachmentBytes))
        _draft = State(initialValue: initialDraft ?? FeedbackDraft.autofilled(platform: client.configuration.defaultPlatform))
        _result = State(initialValue: initialResult)
    }

    public var body: some View {
        Group {
            if let result {
                FeedbackSentView(warning: result.warning, onDismiss: onDismiss ?? { dismiss() }) {
                    withAnimation(.snappy(duration: 0.3)) {
                        self.result = nil
                        self.resetForm()
                    }
                }
            } else if submissionDenial != .none {
                submissionDenial.placeholder
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(CupThreadStrings.tr("cupthread.common.cancel")) {
                                performDismiss()
                            }
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
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
        .task {
            // Read through the shared config cache: the surface gate's fetch
            // (and any other surface's) already warmed it, so presenting the
            // composer costs at most one config GET per TTL window.
            let resolvedConfig: PublicAppConfig?
            if let activeConfig {
                resolvedConfig = activeConfig
            } else {
                resolvedConfig = try? await client.cachedAppConfig()
            }
            if let resolvedConfig {
                attachmentState.applyConfigLimit(resolvedConfig.maxAttachmentBytes)
            }
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
        .composerDismissGuard(
            hasContent: draft.hasContent || attachmentState.isUploading,
            isSubmitting: isSubmitting,
            discardTitleKey: "cupthread.feedback.discard_title"
        )
    }

    private var contentSection: some View {
        Section {
            TextField(
                CupThreadStrings.tr("cupthread.feedback.title_label"),
                text: $draft.title,
                prompt: Text(CupThreadStrings.tr("cupthread.feedback.short_summary"))
            )
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
                    selection: photoSelectionBinding,
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
        FeedbackAttachmentRowView(attachment: attachment) {
            attachmentState.removeAttachment(id: attachment.id, draft: &draft)
        }
    }

    #if canImport(PhotosUI) && !os(tvOS)
    /// Drives the photo selection through the coordinator: a fresh pick
    /// starts its upload attempt, a picker-reported deselection only clears,
    /// and the coordinator clears the selection after every terminal upload
    /// path so re-picking the same photo re-triggers the flow.
    private var photoSelectionBinding: Binding<PhotosPickerItem?> {
        Binding(
            get: { selectionCoordinator.selection },
            set: { newValue in
                guard let newValue else {
                    selectionCoordinator.clearSelection()
                    return
                }
                let task = selectionCoordinator.select(
                    newValue,
                    startUpload: { attachmentState.startUpload() },
                    upload: { item, uploadId in
                        await uploadPhotoItem(item, uploadId: uploadId)
                    }
                )
                uploadHandle?.setCancelHandler { [task] in task.cancel() }
            }
        )
    }

    @MainActor @ViewBuilder
    private var uploadingAttachmentRow: some View {
        FeedbackUploadingAttachmentRowView {
            cancelUpload()
        }
    }

    @MainActor
    private func uploadPhotoItem(_ item: PhotosPickerItem, uploadId: UUID) async {
        attachmentState.clearError()

        do {
            guard let prepared = try await preparePhotoForUpload(item, uploadId: uploadId) else { return }
            defer { PhotoAttachmentHelper.removeTempUploadFile(at: prepared.fileURL) }

            let uploaded = try await client.uploadAttachment(
                fileURL: prepared.fileURL,
                filename: prepared.filename,
                mimeType: prepared.mimeType,
                userToken: userToken
            )

            // Cancellation discards the result. Reset only when this upload
            // is still the active one: an explicit cancel button or a
            // superseding selection has already re-pointed the machine,
            // while an external FeedbackUploadHandle cancel leaves it
            // pointing here and needs this unwind to reset it.
            if Task.isCancelled {
                if attachmentState.activeUploadId == uploadId {
                    attachmentState.cancelUpload()
                }
                return
            }
            guard attachmentState.activeUploadId == uploadId else { return }
            _ = attachmentState.uploadSucceeded(id: uploadId, attachment: uploaded, draft: &draft)
        } catch is CancellationError {
            if attachmentState.activeUploadId == uploadId {
                attachmentState.cancelUpload()
            }
        } catch {
            guard attachmentState.activeUploadId == uploadId else { return }
            if Task.isCancelled {
                attachmentState.cancelUpload()
            } else {
                _ = attachmentState.uploadFailed(id: uploadId, error: error)
            }
        }
    }

    /// Loads the picked photo and normalizes it for the upload API's media
    /// policy: oversized photos are downscaled to fit the configured byte
    /// limit, SVG is rejected locally, HEIC/HEIF photos and unrecognized
    /// containers are transcoded to JPEG, and metadata is stripped.
    ///
    /// The decode/strip/transcode passes are CPU-bound ImageIO work and run
    /// inside the nonisolated async preparation helper on the global
    /// concurrent executor, so awaiting it from the MainActor never blocks
    /// the UI — only the state mutations after the await resume on the
    /// main thread (#79).
    private func loadAndPreparePhotoData(from item: PhotosPickerItem) async throws -> PhotoAttachmentHelper.PreparedPhoto {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw NSError(
                domain: "CupThread",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: CupThreadStrings.tr("cupthread.feedback.photo_load_failed")]
            )
        }
        return try await PhotoAttachmentHelper.prepareForUpload(
            data,
            limit: attachmentState.maxAttachmentBytes,
            stripSensitiveMetadata: stripSensitiveMetadata
        )
    }

    /// A photo readied for the streaming upload path: the spooled temp file
    /// plus the server-facing name and MIME type.
    private struct PreparedPhotoUpload {
        let fileURL: URL
        let filename: String
        let mimeType: String
    }

    /// Prepares the picked photo and spools the upload-ready bytes to a
    /// temporary file so the upload streams from disk instead of holding a
    /// second in-memory copy for the whole network round-trip; the prepared
    /// bytes are released when this returns.
    ///
    /// Returns `nil` when the upload was superseded or cancelled before
    /// preparation finished. Delete the returned file with
    /// ``PhotoAttachmentHelper/removeTempUploadFile(at:)`` when done.
    private func preparePhotoForUpload(
        _ item: PhotosPickerItem,
        uploadId: UUID
    ) async throws -> PreparedPhotoUpload? {
        let prepared = try await loadAndPreparePhotoData(from: item)
        try Task.checkCancellation()
        guard attachmentState.activeUploadId == uploadId else { return nil }

        let fileURL = try await PhotoAttachmentHelper.makeTempUploadFile(
            prepared.data,
            fileExtension: prepared.fileExtension,
            id: uploadId
        )
        return PreparedPhotoUpload(
            fileURL: fileURL,
            filename: PhotoAttachmentHelper.makeFilename(
                fileExtension: prepared.fileExtension,
                id: uploadId
            ),
            mimeType: prepared.mimeType
        )
    }
    #endif

    private var submitBar: some View {
        FeedbackSubmitBarView(
            isSubmitting: isSubmitting,
            canSubmit: canSubmit
        ) {
            Task { await submitDraft() }
        }
    }

    // MARK: Submit

    private var canSubmit: Bool {
        attachmentState.canSubmit(draft: draft)
    }

    @MainActor
    private func submitDraft() async {
        guard submissionDenial == .none else { return }
        guard canSubmit && !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }
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
            guard !error.isSdkCancellation else { return }
            errorMessage = FriendlyError.message(for: error)
        }
    }

    /// Cancels the in-flight upload at an explicit, user-intent-bearing
    /// point: the uploading row's cancel button, a form reset after submit
    /// success, or teardown via ``FeedbackUploadHandle``. Never called from
    /// view lifecycle events — transient disappearances must not stop uploads.
    @MainActor
    private func cancelUpload() {
        #if canImport(PhotosUI) && !os(tvOS)
        selectionCoordinator.cancel()
        #endif
        attachmentState.cancelUpload()
    }

    @MainActor
    private func resetForm() {
        cancelUpload()
        attachmentState.reset(draft: &draft, defaultPlatform: client.configuration.defaultPlatform)
        errorMessage = nil
    }
}
