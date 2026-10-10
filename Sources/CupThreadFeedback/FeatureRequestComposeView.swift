import SwiftUI

/// What dismissal affordance the feature request composer sheet exposes in the navigation bar.
enum FeatureRequestComposeDismissalAffordance: Equatable, Sendable {
    /// The compose sheet shows the permission-denied placeholder with a direct Close button.
    case close
    /// The compose sheet shows the form guarded against accidental discard.
    case guardedCancel
    /// The access verdict has not arrived yet (issue #369): the sheet keeps a
    /// neutral loading state instead of flashing the denial placeholder for a
    /// signed-in user whose provider has not answered.
    case undetermined

    static func resolve(
        config: PublicAppConfig?,
        supportsAuthentication: Bool = false,
        verdictResolved: Bool = true
    ) -> FeatureRequestComposeDismissalAffordance {
        // An unsettled verdict neither denies (that would flash the placeholder
        // for a signed-in user) nor opens the form (that would skip the
        // fail-closed preflight for a signed-out user): the sheet stays
        // neutral until `resolveAuthenticatedAccess()` answers (issue #369).
        guard verdictResolved else { return .undetermined }
        return SdkSubmissionDenial.forFeatureRequest(config: config, supportsAuthentication: supportsAuthentication) != .none
            ? .close
            : .guardedCancel
    }
}

/// Compose sheet for submitting a new feature request proposal.
struct FeatureRequestComposeView: View {
    let client: FeedbackClient
    let userToken: String
    let onSubmitted: () -> Void

    @State private var draft = FeatureRequestDraft()
    @State private var isSubmitting = false
    @State private var submitError: String?
    /// Whether a request sent right now could carry the signed-in identity's
    /// bearer token. Resolved when the sheet appears (issue #297); fail-closed
    /// until then, so a locked-down console never opens the form for a
    /// signed-out user.
    @State private var isAuthenticated: Bool
    /// Whether `isAuthenticated` has been resolved at least once. Before that,
    /// a locked-down config must not produce a denial verdict: the sheet keeps
    /// its neutral loading state instead of flashing the placeholder for a
    /// signed-in user whose provider has not answered (issue #369, mirroring
    /// ``RoadmapBoardView``'s gate).
    @State private var hasResolvedAuthentication: Bool
    @Environment(\.sdkAppConfig) private var sdkAppConfig
    @Environment(\.dismiss) private var dismiss

    private let configOverride: PublicAppConfig?

    /// - Parameters:
    ///   - config: Optional console configuration override (previews/tests).
    ///   - preResolvedAuthentication: Injects the resolved access verdict for
    ///     view-level tests — `nil` leaves the verdict unsettled so the sheet
    ///     starts in its neutral loading state and resolves in `.task` (the
    ///     production presentations), while `true`/`false` inject a settled
    ///     verdict without awaiting `.task`.
    init(
        client: FeedbackClient,
        userToken: String,
        config: PublicAppConfig? = nil,
        preResolvedAuthentication: Bool? = nil,
        onSubmitted: @escaping () -> Void
    ) {
        self.client = client
        self.userToken = userToken
        self.configOverride = config
        self.onSubmitted = onSubmitted
        _isAuthenticated = State(initialValue: preResolvedAuthentication ?? false)
        _hasResolvedAuthentication = State(initialValue: preResolvedAuthentication != nil)
    }

    private var activeConfig: PublicAppConfig? {
        configOverride ?? sdkAppConfig
    }

    var dismissalAffordance: FeatureRequestComposeDismissalAffordance {
        FeatureRequestComposeDismissalAffordance.resolve(
            config: activeConfig,
            supportsAuthentication: isAuthenticated,
            verdictResolved: isAuthenticationVerdictResolved
        )
    }

    /// Whether the denial verdict can be decided: either anonymous proposals
    /// are allowed (the verdict cannot depend on authentication) or the
    /// resolved access state is in (issue #369).
    private var isAuthenticationVerdictResolved: Bool {
        hasResolvedAuthentication || (activeConfig?.allowsAnonymousFeedback ?? true)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch dismissalAffordance {
                case .undetermined:
                    // Neutral loading state while the access verdict is in
                    // flight (issue #369): neither the denial placeholder nor
                    // the interactive form. The sheet's swipe-down dismissal
                    // stays available as the escape hatch.
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("cupthread.features.compose_verdict_loading")
                case .close:
                    SdkSubmissionDenial.anonymousFeedbackDisabled.featureRequestPlaceholder
                case .guardedCancel:
                    formContent
                        .composerDismissGuard(
                            hasContent: draft.hasContent,
                            isSubmitting: isSubmitting,
                            discardTitleKey: "cupthread.features.compose_discard_title"
                        )
                }
            }
            .navigationTitle(CupThreadStrings.tr("cupthread.features.compose_title"))
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 420)
            #endif
            .task {
                isAuthenticated = await client.resolveAuthenticatedAccess()
                hasResolvedAuthentication = true
            }
            .toolbar {
                if dismissalAffordance == .close {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(CupThreadStrings.tr("cupthread.whatsnew.close_button")) {
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private var formContent: some View {
        Form {
            Section {
                TextField(
                    CupThreadStrings.tr("cupthread.feedback.title_label"),
                    text: $draft.title,
                    prompt: Text(CupThreadStrings.tr("cupthread.feedback.short_summary"))
                )
                intakeCharacterCounter(draft.title, limit: IntakeTextLimits.maxTitleLength, styledAsFormRow: true)
                TextField(CupThreadStrings.tr("cupthread.feedback.description_label"), text: $draft.description, axis: .vertical)
                    .lineLimit(5...10)
                    .padding(.top, 2)
                intakeCharacterCounter(draft.description, limit: IntakeTextLimits.maxDescriptionLength, styledAsFormRow: true)
            } header: {
                Text(CupThreadStrings.tr("cupthread.feedback.section_feedback"))
            } footer: {
                Text(CupThreadStrings.tr("cupthread.features.compose_desc_prompt"))
            }

            Section {
                TextField(CupThreadStrings.tr("cupthread.features.compose_name_prompt"), text: $draft.requesterName)
                intakeCharacterCounter(draft.requesterName, limit: IntakeTextLimits.maxNameLength, styledAsFormRow: true)
            } header: {
                Text(CupThreadStrings.tr("cupthread.feedback.section_contact"))
            } footer: {
                Text(CupThreadStrings.tr("cupthread.feedback.section_contact_footer"))
            }

            if let submitError {
                Section {
                    ErrorBanner(message: submitError)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(
                    isSubmitting
                        ? CupThreadStrings.tr("cupthread.features.compose_sending")
                        : CupThreadStrings.tr("cupthread.features.compose_submit")
                ) {
                    Task { await submit() }
                }
                .disabled(isSubmitting || !canSubmit)
            }
        }
    }

    private var canSubmit: Bool {
        draft.title.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 &&
        draft.description.trimmingCharacters(in: .whitespacesAndNewlines).count >= 5 &&
        IntakeTextLimits.overLimitField(in: draft) == nil
    }

    @MainActor
    private func submit() async {
        guard SdkSubmissionDenial.forFeatureRequest(
            config: activeConfig,
            supportsAuthentication: isAuthenticated
        ) == .none else { return }
        isSubmitting = true
        submitError = nil
        defer { isSubmitting = false }
        do {
            _ = try await client.submitFeatureRequest(draft, userToken: userToken)
            onSubmitted()
        } catch {
            guard !error.isSdkCancellation else { return }
            submitError = FriendlyError.message(for: error)
        }
    }
}
