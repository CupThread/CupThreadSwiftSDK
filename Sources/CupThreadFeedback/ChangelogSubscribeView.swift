import SwiftUI

// MARK: - Subscribe sheet

/// Sheet for subscribing to the app's changelog email updates.
///
/// Opens statefully: when a subscription is remembered for this app key
/// (see `ChangelogSubscriptionStore`), the sheet starts in the manage phase
/// showing the subscribed address with a safe close action; otherwise it
/// starts on the blank email form. A successful subscribe persists the
/// address so later presentations skip the form.
struct ChangelogSubscribeView: View {
    /// Presentation phases of the sheet.
    enum Phase: Equatable {
        /// Blank email form; shown when no subscription is remembered.
        case form
        /// Subscription just recorded; awaiting the emailed double opt-in.
        case subscribed
        /// Returning user; shows the remembered subscribed address.
        case manage
    }

    /// The phase a sheet should open in for the given remembered state.
    static func initialPhase(subscribedEmail: String?) -> Phase {
        subscribedEmail == nil ? .form : .manage
    }

    let client: FeedbackClient
    let userToken: String

    private let store: ChangelogSubscriptionStore

    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var rememberedEmail: String
    @State private var phase: Phase
    @State private var isWorking = false
    @State private var errorMessage: String?

    init(client: FeedbackClient, userToken: String) {
        self.client = client
        self.userToken = userToken
        let store = ChangelogSubscriptionStore(appKey: client.configuration.appKey)
        self.store = store
        let remembered = store.subscribedEmail()
        _rememberedEmail = State(initialValue: remembered ?? "")
        _phase = State(initialValue: Self.initialPhase(subscribedEmail: remembered))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .form:
                    form
                case .subscribed:
                    resultView(
                        icon: "envelope.badge.checkmark.fill",
                        tint: .green,
                        title: "Check Your Inbox",
                        message: "We sent a confirmation link to \(trimmedEmail). Confirm it to start receiving update emails."
                    )
                case .manage:
                    manageView
                }
            }
            .navigationTitle("Updates by Email")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 380)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if phase == .form {
                        Button("Cancel") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmationTitle) {
                        Task { await runPrimaryAction() }
                    }
                    .disabled(isWorking || (phase == .form && !isValidEmail))
                }
            }
        }
    }

    // MARK: Form

    private var form: some View {
        Form {
            Section {
                TextField("you@example.com", text: $email)
                    #if canImport(UIKit)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    #endif
            } header: {
                Text("Email")
            } footer: {
                Text("We'll email you a confirmation link; only confirmed addresses receive updates. "
                    + "You can unsubscribe anytime using the link in any update email.")
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

            Text("You're Subscribed")
                .font(.title3.weight(.semibold))

            Text("Update emails will go to \(rememberedEmail). To change the address or unsubscribe, "
                + "use the link in any update email.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Use a Different Email") {
                email = ""
                errorMessage = nil
                phase = .form
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

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lightweight shape check — full validation happens server-side.
    private var isValidEmail: Bool {
        let trimmed = trimmedEmail
        guard let at = trimmed.firstIndex(of: "@"),
              at != trimmed.startIndex,
              at != trimmed.index(before: trimmed.endIndex),
              trimmed.suffix(from: at).contains(".") else {
            return false
        }
        return !trimmed.contains(where: \.isWhitespace)
    }

    private var confirmationTitle: String {
        switch phase {
        case .form:
            return isWorking ? "Subscribing…" : "Subscribe"
        case .subscribed, .manage:
            return "Done"
        }
    }

    @MainActor
    private func runPrimaryAction() async {
        switch phase {
        case .form:
            await subscribe()
        case .subscribed, .manage:
            dismiss()
        }
    }

    @MainActor
    private func subscribe() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            _ = try await client.subscribeToChangelog(email: trimmedEmail, userToken: userToken)
            store.persist(email: trimmedEmail)
            withAnimation(.snappy(duration: 0.3)) {
                phase = .subscribed
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
