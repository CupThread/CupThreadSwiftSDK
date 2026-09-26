import SwiftUI

// MARK: - Subscribe sheet

/// Sheet for subscribing to the app's changelog email updates.
///
/// Opens statefully: when a subscription is remembered for this app key
/// (see `ChangelogSubscriptionStore`), the sheet starts in the manage phase
/// showing the subscribed address with a safe close action; otherwise it
/// starts on the blank email form. A successful subscribe persists the
/// address so later presentations skip the form.
///
/// Phase and toolbar decisions are owned by `ChangelogSubscribeModel`, which
/// guarantees a close affordance in every phase — so on platforms without
/// swipe-to-dismiss (macOS, tvOS, visionOS) the sheet can always be closed
/// in one tap without any network call. Unsubscribing happens out-of-band
/// through the emailed link, never through a button in this sheet.
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
        _model = State(initialValue: ChangelogSubscribeModel(subscribedEmail: store.subscribedEmail()))
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

    /// Returning-user state: the remembered address with a safe close action.
    /// Unsubscription happens through the emailed link, so nothing here can
    /// accidentally remove the subscription.
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
            store.persist(email: model.trimmedEmail)
            withAnimation(.snappy(duration: 0.3)) {
                model.didSubscribe()
            }
        } catch {
            guard !error.isSdkCancellation else { return }
            errorMessage = FriendlyError.message(for: error)
        }
    }
}
