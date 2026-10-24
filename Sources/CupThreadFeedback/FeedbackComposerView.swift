// swiftlint:disable file_length
// One surface per file: the view's @State must stay file-private, so the
// body is organized by MARK sections rather than split across files to fit
// the size budget (same policy as the oversized test suites, .swiftlint.yml).
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
    /// Human-verification challenge awaiting the widget's token (#53 Phase 2).
    @State private var pendingChallenge: PendingTurnstileChallenge?
    /// Bearer-token availability right now; fail-closed until `.task` resolves it (issue #297).
    @State private var isAuthenticated = false
    /// Whether `isAuthenticated` has been resolved at least once. Before that,
    /// a locked-down config must not produce a denial verdict: the composer
    /// keeps its neutral loading state instead of flashing the placeholder for
    /// a signed-in user whose provider has not answered (issue #367, mirroring
    /// ``RoadmapBoardView``'s gate).
    @State private var hasResolvedAuthentication = false
    @Environment(\.sdkAppConfig) private var sdkAppConfig
    @Environment(\.dismiss) private var dismiss

    private var activeConfig: PublicAppConfig? { config ?? sdkAppConfig }

    /// Whether the denial verdict can be decided: either anonymous feedback is
    /// allowed (the verdict cannot depend on authentication) or the resolved
    /// access state is in (issue #367).
    private var isAuthenticationVerdictResolved: Bool {
        hasResolvedAuthentication || (activeConfig?.allowsAnonymousFeedback ?? true)
    }

    private var submissionDenial: SdkSubmissionDenial {
        // An unsettled verdict neither denies (that would flash the placeholder
        // for a signed-in user) nor opens the form (that would skip the
        // fail-closed preflight for a signed-out user): the body renders the
        // neutral loading state until `resolveAuthenticatedAccess()` answers
        // (issue #367).
        guard isAuthenticationVerdictResolved else { return .none }
        return SdkSubmissionDenial.forFeedback(
            config: activeConfig,
            platform: draft.platform,
            supportsAuthentication: isAuthenticated
        )
    }

    var dismissalAffordance: FeedbackComposerDismissalAffordance {
        FeedbackComposerDismissalAffordance.resolve(
            result: result, denial: submissionDenial, verdictResolved: isAuthenticationVerdictResolved
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
    /// characters) before enabling the send button, applies the
    /// ``IntakeTextLimits`` caps with near-cap character counters (BUG-18),
    /// shows an inline error banner on failure, and swaps to a success
    /// screen on completion.
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
    ///     ``PublicAppConfig/maxAttachmentBytes``, then to the last-known limit
    ///     from an earlier fetch, ultimately to ``PhotoAttachmentHelper/defaultMaxAttachmentBytes``
    ///     (20 MB) on first run. Photos larger than the limit are automatically
    ///     downscaled and re-encoded as JPEG to fit before upload (see
    ///     ``PhotoAttachmentHelper/downscaledImageData(_:limit:maxDimension:)``).
    ///   - stripSensitiveMetadata: When `true` (the default), photo attachments selected
    ///     via the photo picker are re-encoded to strip GPS coordinates, camera details,
    ///     and sensitive EXIF metadata before upload. Multi-frame animations (such as GIF or
    ///     animated WebP) are preserved intact without flattening to a still image;
    ///     container-embedded EXIF/XMP metadata (including GPS) is stripped from them
    ///     at the byte level without re-encoding.
    ///     Set to `false` to upload original bytes for formats accepted as-is (PNG, JPEG, WebP, GIF);
    ///     note that HEIC/HEIF and unrecognized formats are always transcoded to JPEG per server media policy.
    ///   - uploadHandle: Optional ``FeedbackUploadHandle`` for cancelling the
    ///     in-flight attachment upload from outside the view — e.g. from a
    ///     sheet's `onDismiss` closure. Uploads are never cancelled by view
    ///     lifecycle events; see ``FeedbackComposerView``.
    ///   - config: Optional ``PublicAppConfig`` override for previewing or testing permissions.
    ///   - preResolvedAuthentication: Injects the resolved access verdict for
    ///     view-level tests — `nil` leaves the verdict unsettled so the composer
    ///     starts in its neutral loading state and resolves in `.task` (the
    ///     production presentations), while `true`/`false` inject a settled
    ///     verdict without awaiting `.task`.
    ///   - initialResult: Optional initial submission result for testing the sent confirmation state.
    ///   - onDismiss: Optional dismissal action callback.
    ///   - onSubmit: Called with the server's receipt after a successful
    ///     submission — use it to log, show a toast, or deep-link elsewhere.
    ///     Inspect ``FeedbackSubmissionResult/warningCode`` to branch on structured
    ///     server warnings; ``FeedbackSubmissionResult/warning`` contains the raw
    ///     server-provided diagnostic string and should not be displayed directly to users.
    public init(
        client: FeedbackClient,
        initialDraft: FeedbackDraft? = nil,
        userToken: String? = nil,
        maxAttachmentBytes: Int? = nil,
        stripSensitiveMetadata: Bool = true,
        uploadHandle: FeedbackUploadHandle? = nil,
        config: PublicAppConfig? = nil,
        preResolvedAuthentication: Bool? = nil,
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
        _isAuthenticated = State(initialValue: preResolvedAuthentication ?? false)
        _hasResolvedAuthentication = State(initialValue: preResolvedAuthentication != nil)
    }

    public var body: some View {
        Group {
            if let result {
                FeedbackSentView(
                    warning: result.warning,
                    warningCode: result.warningCode,
                    onDismiss: onDismiss ?? { dismiss() }
                ) {
                    withAnimation(.snappy(duration: 0.3)) {
                        self.result = nil
                        self.resetForm()
                    }
                }
            } else if submissionDenial != .none {
                submissionDenial.placeholder
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(CupThreadStrings.tr("cupthread.common.cancel")) { performDismiss() }
                        }
                    }
            } else if !isAuthenticationVerdictResolved {
                // Neutral loading state while the access verdict is in flight
                // (issue #367): neither the denial placeholder nor the
                // interactive form. The sheet's swipe-down dismissal stays
                // available as the escape hatch.
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("cupthread.feedback.composer_verdict_loading")
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
            // composer costs at most one config GET per TTL window. A failed
            // read keeps the last-known console limit in force (#287) instead
            // of the compiled-in default — the downscale driver input (#52).
            let resolvedConfig: PublicAppConfig? = if let activeConfig { activeConfig } else { try? await client.cachedAppConfig() }
            if let limit = FeedbackComposerAttachmentLimit.resolve(
                config: resolvedConfig, lastKnownLimit: client.configStore.lastKnownMaxAttachmentBytes()
            ) { attachmentState.applyConfigLimit(limit) }
            isAuthenticated = await client.resolveAuthenticatedAccess()
            hasResolvedAuthentication = true
        }
        .sdkSurface(client: client, feature: .feedback)
        .turnstileChallengeSheet($pendingChallenge)
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
            intakeCharacterCounter(draft.title, limit: IntakeTextLimits.maxTitleLength, styledAsFormRow: true)
            TextField(CupThreadStrings.tr("cupthread.feedback.description_label"), text: $draft.description, axis: .vertical)
                .lineLimit(6...12)
                .padding(.top, 2)
                #if canImport(UIKit)
                .submitLabel(.send)
                #endif
            intakeCharacterCounter(draft.description, limit: IntakeTextLimits.maxDescriptionLength, styledAsFormRow: true)
        } header: {
            Text(CupThreadStrings.tr("cupthread.feedback.section_feedback"))
        } footer: {
            Text(CupThreadStrings.tr("cupthread.feedback.section_feedback_footer"))
        }
    }

    private var contactSection: some View {
        Section {
            TextField(CupThreadStrings.tr("cupthread.feedback.name_label"), text: $draft.reporterName)
            intakeCharacterCounter(draft.reporterName, limit: IntakeTextLimits.maxNameLength, styledAsFormRow: true)
            TextField(CupThreadStrings.tr("cupthread.feedback.email_label"), text: $draft.reporterEmail)
                #if canImport(UIKit)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                #endif
                .feedbackEmailHint(draft.reporterEmail)
            intakeCharacterCounter(draft.reporterEmail, limit: IntakeTextLimits.maxEmailLength, styledAsFormRow: true)
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

    #endif

    private var submitBar: some View {
        FeedbackSubmitBarView(isSubmitting: isSubmitting, canSubmit: attachmentState.canSubmit(draft: draft)) {
            Task { await submitDraft() }
        }
    }

    // MARK: - Submit

    @MainActor
    private func submitDraft(turnstileToken: String? = nil) async {
        guard submissionDenial == .none else { return }
        guard attachmentState.canSubmit(draft: draft) && !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        errorMessage = nil
        let currentDraft = draft
        let currentClient = client

        do {
            let result = try await currentClient.submit(
                currentDraft,
                userToken: userToken,
                turnstileToken: turnstileToken
            )
            onSubmit(result)
            withAnimation(.snappy(duration: 0.3)) {
                self.result = result
                self.resetForm()
            }
        } catch {
            guard !error.isSdkCancellation else { return }
            if presentChallengeIfNeeded(for: error, challenge: .feedback(appKey: currentClient.configuration.appKey)) {
                return
            }
            if Self.clearsConsumedAttachments(for: error) {
                // The server rejected a duplicate attachment (#257): the upload ID was already
                // finalized into another submission. Clear upload-bearing attachments from the
                // draft so the user does not retry the same consumed IDs.
                for attachment in draft.attachments where attachment.uploadId != nil {
                    attachmentState.removeAttachment(id: attachment.id, draft: &draft)
                }
            }
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

    /// Presents the human-verification sheet when a rejected submission can be
    /// resolved with the hosted challenge (#53 Phase 2), keeping the draft
    /// intact. Returns `true` when the sheet took over the failure.
    @MainActor
    private func presentChallengeIfNeeded(for error: Error, challenge: TurnstileChallenge) -> Bool {
        guard let clientError = error as? FeedbackClientError,
              case .turnstileRequired = clientError,
              let presentation = client.turnstileChallengePresentation(
                  for: challenge,
                  config: activeConfig,
                  theme: activeConfig?.sdk.theme ?? .system
              )
        else { return false }
        // A submission can still be in flight while a photo upload starts, so
        // both calls can be gated. The first challenge owns the sheet; let the
        // submission fall through to its normal error copy rather than replace
        // the pending challenge and drop the other attempt's cleanup (#539).
        guard pendingChallenge == nil else { return false }
        pendingChallenge = PendingTurnstileChallenge(
            presentation: presentation,
            resume: { token in
                Task { await submitDraft(turnstileToken: token) }
            },
            cancel: { errorMessage = FriendlyError.message(for: error) }
        )
        return true
    }
}

// MARK: - Photo upload pipeline

/// Extracted from the composer's main type body to keep it within the
/// 350-line `type_body_length` budget (`.swiftlint.yml`); it stays in this
/// file because the pipeline drives the view's file-private `@State` (same
/// one-surface-per-file policy as the header note).
extension FeedbackComposerView {
    #if canImport(PhotosUI) && !os(tvOS)
    @MainActor
    private func uploadPhotoItem(_ item: PhotosPickerItem, uploadId: UUID) async {
        attachmentState.clearError()

        do {
            guard let prepared = try await preparePhotoForUpload(item, uploadId: uploadId) else { return }
            try await sendPreparedPhoto(prepared, uploadId: uploadId, turnstileToken: nil)
        } catch {
            recordUploadFailure(error, uploadId: uploadId)
        }
    }

    /// Streams prepared bytes into an upload session and records the outcome.
    ///
    /// When the server's Turnstile gate rejects the session creation and this
    /// client can present the hosted challenge, the sheet takes over: the
    /// spooled file stays alive until the widget answers, then the upload
    /// resumes with the freshly minted token (#53 Phase 2). Every terminal
    /// path removes the spooled file.
    @MainActor
    private func sendPreparedPhoto(
        _ prepared: PreparedPhotoUpload,
        uploadId: UUID,
        turnstileToken: String?
    ) async throws {
        // Re-validate across the resume boundary (#423): the checks in
        // `preparePhotoForUpload` only held at its return, and a
        // superseding selection or handle cancel can land during the hop
        // back to the main actor. Skip the doomed network round-trip
        // instead of creating a backend upload session and streaming
        // obsolete bytes over it.
        switch PhotoUploadAdmission.resolve(
            isCancelled: Task.isCancelled,
            isActiveUpload: attachmentState.activeUploadId == uploadId
        ) {
        case .proceed:
            break
        case .cancelledWhileActive:
            PhotoAttachmentHelper.removeTempUploadFile(at: prepared.fileURL)
            attachmentState.cancelUpload()
            return
        case .superseded:
            PhotoAttachmentHelper.removeTempUploadFile(at: prepared.fileURL)
            return
        }

        let uploaded: FeedbackAttachment
        do {
            uploaded = try await client.uploadAttachment(
                fileURL: prepared.fileURL,
                filename: prepared.filename,
                mimeType: prepared.mimeType,
                userToken: userToken,
                turnstileToken: turnstileToken
            )
        } catch {
            guard turnstileToken == nil,
                  !error.isSdkCancellation,
                  attachmentState.activeUploadId == uploadId,
                  let clientError = error as? FeedbackClientError,
                  case .turnstileRequired = clientError
            else {
                PhotoAttachmentHelper.removeTempUploadFile(at: prepared.fileURL)
                throw error
            }
            presentUploadChallenge(for: clientError, prepared: prepared, uploadId: uploadId)
            return
        }

        PhotoAttachmentHelper.removeTempUploadFile(at: prepared.fileURL)

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
    }

    /// Presents the hosted challenge for a gated upload-session creation and
    /// resumes the spooled upload once the widget mints a token. Without a
    /// resolvable presentation the typed gate error lands on the row.
    @MainActor
    private func presentUploadChallenge(
        for error: FeedbackClientError,
        prepared: PreparedPhotoUpload,
        uploadId: UUID
    ) {
        // The submission path may already own the sheet. Fail this upload
        // through its normal cleanup instead of replacing the pending
        // challenge, which would leave this attempt in `.uploading` with an
        // orphaned spool (#539).
        guard pendingChallenge == nil else {
            PhotoAttachmentHelper.removeTempUploadFile(at: prepared.fileURL)
            recordUploadFailure(error, uploadId: uploadId)
            return
        }
        guard let presentation = client.turnstileChallengePresentation(
            for: .feedback(appKey: client.configuration.appKey),
            config: activeConfig,
            theme: activeConfig?.sdk.theme ?? .system
        ) else {
            PhotoAttachmentHelper.removeTempUploadFile(at: prepared.fileURL)
            recordUploadFailure(error, uploadId: uploadId)
            return
        }
        pendingChallenge = PendingTurnstileChallenge(
            presentation: presentation,
            resume: { token in
                Task {
                    do {
                        try await sendPreparedPhoto(prepared, uploadId: uploadId, turnstileToken: token)
                    } catch {
                        recordUploadFailure(error, uploadId: uploadId)
                    }
                }
            },
            cancel: {
                PhotoAttachmentHelper.removeTempUploadFile(at: prepared.fileURL)
                recordUploadFailure(error, uploadId: uploadId)
            }
        )
    }

    /// Records a terminal upload error for `uploadId` — cancellation resets
    /// the machine, any other failure shows on the attachment row.
    @MainActor
    private func recordUploadFailure(_ error: Error, uploadId: UUID) {
        guard attachmentState.activeUploadId == uploadId else { return }
        if error.isSdkCancellation || Task.isCancelled {
            attachmentState.cancelUpload()
        } else {
            _ = attachmentState.uploadFailed(id: uploadId, error: error)
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

    /// Prepares the picked photo and spools the upload-ready bytes to a
    /// temporary file so the upload streams from disk instead of holding a
    /// second in-memory copy for the whole network round-trip; the prepared
    /// bytes are released when this returns.
    ///
    /// Returns `nil` when the upload was superseded or cancelled before
    /// preparation finished — including while the spooled file was being
    /// written, in which case the file is removed before returning so no
    /// orphan is left behind in the temporary directory (#423). Delete the
    /// returned file with ``PhotoAttachmentHelper/removeTempUploadFile(at:)``
    /// when done.
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

        // The spool ran across awaits, so the write may have been racing a
        // cancellation or a superseding selection the whole time. Re-validate
        // before handing the file out, removing it when the upload is already
        // doomed (#423).
        switch PhotoUploadAdmission.resolve(
            isCancelled: Task.isCancelled,
            isActiveUpload: attachmentState.activeUploadId == uploadId
        ) {
        case .proceed:
            break
        case .cancelledWhileActive:
            PhotoAttachmentHelper.removeTempUploadFile(at: fileURL)
            // Same unwind as the pre-spool `checkCancellation`: the catch in
            // `uploadPhotoItem` resets the still-active machine.
            throw CancellationError()
        case .superseded:
            PhotoAttachmentHelper.removeTempUploadFile(at: fileURL)
            return nil
        }

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
}
