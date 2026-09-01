import SwiftUI

/// Compose sheet for submitting a new feature request proposal.
struct FeatureRequestComposeView: View {
    let client: FeedbackClient
    let userToken: String
    let onSubmitted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = FeatureRequestDraft()
    @State private var isSubmitting = false
    @State private var submitError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(CupThreadStrings.tr("cupthread.feedback.title_label"), text: $draft.title, prompt: Text(CupThreadStrings.tr("cupthread.feedback.short_summary")))
                    TextField(CupThreadStrings.tr("cupthread.feedback.description_label"), text: $draft.description, axis: .vertical)
                        .lineLimit(5...10)
                        .padding(.top, 2)
                } header: {
                    Text(CupThreadStrings.tr("cupthread.feedback.section_feedback"))
                } footer: {
                    Text(CupThreadStrings.tr("cupthread.features.compose_desc_prompt"))
                }

                Section {
                    TextField(CupThreadStrings.tr("cupthread.features.compose_name_prompt"), text: $draft.requesterName)
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
            .navigationTitle(CupThreadStrings.tr("cupthread.features.compose_title"))
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 420)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(CupThreadStrings.tr("cupthread.whatsnew.close_button")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSubmitting ? CupThreadStrings.tr("cupthread.features.compose_sending") : CupThreadStrings.tr("cupthread.features.compose_submit")) {
                        Task { await submit() }
                    }
                    .disabled(isSubmitting || !canSubmit)
                }
            }
        }
    }

    private var canSubmit: Bool {
        draft.title.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 &&
        draft.description.trimmingCharacters(in: .whitespacesAndNewlines).count >= 5
    }

    @MainActor
    private func submit() async {
        isSubmitting = true
        submitError = nil
        defer { isSubmitting = false }
        do {
            _ = try await client.submitFeatureRequest(draft, userToken: userToken)
            onSubmitted()
        } catch {
            submitError = error.localizedDescription
        }
    }
}
