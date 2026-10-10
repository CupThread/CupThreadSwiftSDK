import SwiftUI

// MARK: - Subscribe sheet

/// Sheet for subscribing to the app's changelog email updates.
///
/// Opens statefully: when a subscription is remembered for this app key
/// (see `ChangelogSubscriptionStore`), the sheet starts in a manage phase —
/// pending when the emailed double opt-in is still outstanding (offering a
/// resend action), manage once confirmed; otherwise it starts on the blank
/// email form. A successful subscribe persists the address as pending so
/// later presentations stay honest about the confirmation step (issue #273).
///
/// Phase and toolbar decisions are owned by `ChangelogSubscribeModel`, which
/// guarantees a close affordance in every phase — so on platforms without
/// swipe-to-dismiss (macOS, tvOS, visionOS) the sheet can always be closed
/// in one tap. Unsubscribing happens out-of-band through the emailed link,
/// never through a button in this sheet.
struct ChangelogSubscribeView: View {
    let client: FeedbackClient
    let userToken: String

    private let store: ChangelogSubscriptionStore

    @Environment(\.dismiss) private var dismiss
    @State private var model: ChangelogSubscribeModel
    @State private var errorMessage: String?

    init(client: FeedbackClient, userToken: String) {
        self.client = client
        self.userToken = userToken
        let store = ChangelogSubscriptionStore(appKey: client.configuration.appKey)
        self.store = store
        _model = State(initialValue: ChangelogSubscribeModel(record: store.subscriptionRecord()))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .form:
                    form
                case .subscribed:
                    resultView(
                        icon: "envelope.badge.checkmark.fill",
                        tint: .green,
                        title: CupThreadStrings.tr("cupthread.subscribe.check_inbox_title"),
                        message: CupThreadStrings.tr(
                            "cupthread.subscribe.check_inbox_message", model.trimmedEmail
                        )
                    )
                case .manage:
                    manageView
                case .managePending:
                    pendingManageView
                }
            }
            .navigationTitle(CupThreadStrings.tr("cupthread.subscribe.title"))
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 380)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // In later phases the confirmation button is itself the
                    // close affordance, so no second dismissal control is
                    // rendered.
                    if model.phase == .form {
                        Button(CupThreadStrings.tr("cupthread.common.cancel")) { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.primaryTitle) {
                        Task { await runPrimaryAction() }
                    }
                    .disabled(model.isPrimaryDisabled)
                }
            }
        }
    }

    // MARK: Form

    private var form: some View {
        Form {
            Section {
                TextField(
                    CupThreadStrings.tr("cupthread.subscribe.email_placeholder"),
                    text: $model.email
                )
                    #if canImport(UIKit)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    #endif
            } header: {
                Text(CupThreadStrings.tr("cupthread.subscribe.email_header"))
            } footer: {
                Text(CupThreadStrings.tr("cupthread.subscribe.email_footer"))
            }

            if let errorMessage {
                Section {
                    ErrorBanner(message: errorMessage)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                }
            }
        }
    }

    /// Confirmed returning-user state: the remembered address with a safe
    /// close action. Unsubscription happens through the emailed link, so
    /// nothing here can accidentally remove the subscription.
    private var manageView: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 24)

            Image(systemName: "envelope.open.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            Text(CupThreadStrings.tr("cupthread.subscribe.manage_title"))
                .font(.title3.weight(.semibold))

            Text(CupThreadStrings.tr(
                "cupthread.subscribe.manage_message", model.rememberedEmail
            ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(CupThreadStrings.tr("cupthread.subscribe.use_different_email")) {
                model.startNewEmailEntry()
                errorMessage = nil
            }
            .font(.subheadline.weight(.medium))

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityElement(children: .contain)
    }

    /// Pending returning-user state: the double opt-in is still outstanding,
    /// so the copy names the confirmation step instead of claiming the
    /// subscription is active, and the confirmation email can be resent
    /// (the endpoint re-dispatches it; its 15-minute cooldown suppresses
    /// duplicate sends).
    private var pendingManageView: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 24)

            Image(systemName: "envelope.open.badge.clock")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text(CupThreadStrings.tr("cupthread.subscribe.pending_title"))
                .font(.title3.weight(.semibold))

            Text(CupThreadStrings.tr(
                "cupthread.subscribe.pending_message", model.rememberedEmail
            ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let errorMessage {
                ErrorBanner(message: errorMessage)
                    .padding(.horizontal, 8)
            } else if model.hasResentConfirmation {
                // Affirms the latest resend so the user is not left guessing
                // whether the tap landed and retrying blind (issue #373).
                resendSentBanner
            }

            Button {
                Task { await resendConfirmation() }
            } label: {
                if model.isResending {
                    ProgressView()
                        .padding(.horizontal, 12)
                } else {
                    Text(CupThreadStrings.tr("cupthread.subscribe.resend_button"))
                }
            }
            .font(.subheadline.weight(.medium))
            .disabled(model.isResending)

            Button(CupThreadStrings.tr("cupthread.subscribe.use_different_email")) {
                model.startNewEmailEntry()
                errorMessage = nil
            }
            .font(.subheadline.weight(.medium))

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityElement(children: .contain)
    }

    /// Success counterpart to `ErrorBanner` for the pending phase's resend
    /// action: same footprint, affirmative green styling (issue #373).
    private var resendSentBanner: some View {
        Label {
            Text(CupThreadStrings.tr("cupthread.subscribe.resend_sent_message"))
                .font(.footnote)
                .multilineTextAlignment(.leading)
        } icon: {
            Image(systemName: "checkmark.circle.fill")
        }
        .foregroundStyle(.green)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.green.opacity(0.2), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }

    private func resultView(icon: String, tint: Color, title: String, message: String) -> some View {
        VStack(spacing: 14) {
            Spacer(minLength: 24)

            Image(systemName: icon)
                .font(.system(size: 56))
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            Text(title)
                .font(.title3.weight(.semibold))

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityElement(children: .contain)
    }

    // MARK: Actions

    @MainActor
    private func runPrimaryAction() async {
        switch model.primaryAction {
        case .subscribe:
            await subscribe()
        case .close:
            dismiss()
        }
    }

    @MainActor
    private func subscribe() async {
        model.isWorking = true
        errorMessage = nil
        defer { model.isWorking = false }
        do {
            _ = try await client.subscribeToChangelog(email: model.trimmedEmail, userToken: userToken)
            store.persist(
                record: ChangelogSubscriptionRecord(
                    email: model.trimmedEmail,
                    state: .pending(since: .now)
                )
            )
            withAnimation(.snappy(duration: 0.3)) {
                model.didSubscribe()
            }
        } catch {
            guard !error.isSdkCancellation else { return }
            errorMessage = FriendlyError.message(for: error)
        }
    }

    @MainActor
    private func resendConfirmation() async {
        model.willResendConfirmation()
        errorMessage = nil
        defer { model.isResending = false }
        do {
            _ = try await client.subscribeToChangelog(email: model.rememberedEmail, userToken: userToken)
            store.persist(
                record: ChangelogSubscriptionRecord(
                    email: model.rememberedEmail,
                    state: .pending(since: .now)
                )
            )
            withAnimation(.snappy(duration: 0.3)) {
                model.didResendConfirmation()
            }
        } catch {
            guard !error.isSdkCancellation else { return }
            errorMessage = FriendlyError.message(for: error)
        }
    }
}
