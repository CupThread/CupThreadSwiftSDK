import SwiftUI

// MARK: - WhatsNewView

/// The public "What's New" surface fed by the app's changelog.
///
/// Entries are listed newest-first with a version badge, friendly date, body
/// text, and chips for the feature requests that shipped. iPhone, iPad, macOS,
/// and visionOS show a card list; tvOS uses a focus-friendly `List`. A toolbar
/// button (plus a footer entry point) opens the email subscription sheet.
public struct WhatsNewView: View {
    public let client: FeedbackClient
    public let userToken: String

    @State private var entries: [ChangelogEntry] = []
    @State private var isLoading = true
    /// True once the first load finished. Later reloads keep showing content
    /// instead of flashing skeletons.
    @State private var hasLoadedOnce = false
    @State private var loadError: String?
    @State private var isSubscribePresented = false

    /// Creates the "What's New" view.
    /// - Parameters:
    ///   - client: The shared ``FeedbackClient``.
    ///   - userToken: Anonymous token identifying this user; links email
    ///     subscriptions made from this view to the end-user identity.
    public init(client: FeedbackClient, userToken: String) {
        self.client = client
        self.userToken = userToken
    }

    public var body: some View {
        Group {
            #if os(tvOS)
            tvList
            #else
            cardScroll
            #endif
        }
        .navigationTitle(CupThreadStrings.tr("cupthread.whatsnew.title"))
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            subscribeToolbarItem
        }
        .sheet(isPresented: $isSubscribePresented) {
            ChangelogSubscribeView(client: client, userToken: userToken)
        }
        .refreshable { await loadEntries() }
        .task { await loadEntries() }
        .sdkSurface(client: client, feature: .changelog)
    }

    // MARK: Content

    private var cardScroll: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if isLoading && !hasLoadedOnce {
                    SkeletonCardList()
                } else if let loadError {
                    LoadErrorView(message: loadError) {
                        await loadEntries()
                    }
                    .padding(.top, 32)
                } else {
                    if entries.isEmpty {
                        emptyState
                            .padding(.top, 48)
                            .padding(.bottom, 8)
                    }
                    ForEach(entries) { entry in
                        ChangelogEntryCard(entry: entry)
                    }
                    SubscribeFooterCard {
                        isSubscribePresented = true
                    }
                }
            }
            .padding(16)
        }
    }

    // tvOS: plain list rows keep the focus engine happy.
    private var tvList: some View {
        List {
            if isLoading && !hasLoadedOnce {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if let loadError {
                LoadErrorView(message: loadError) {
                    await loadEntries()
                }
                .frame(maxWidth: .infinity)
            } else {
                if entries.isEmpty {
                    Text(CupThreadStrings.tr("cupthread.whatsnew.no_updates_tv"))
                        .foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    ChangelogEntryCard(entry: entry)
                        #if !os(tvOS)
                        .listRowSeparator(.hidden)
                        #endif
                }
                Button {
                    isSubscribePresented = true
                } label: {
                    Label(CupThreadStrings.tr("cupthread.whatsnew.subscribe_button"), systemImage: "envelope")
                }
            }
        }
        .refreshable { await loadEntries() }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(CupThreadStrings.tr("cupthread.whatsnew.no_updates_title"), systemImage: "sparkles")
        } description: {
            Text(CupThreadStrings.tr("cupthread.whatsnew.no_updates_desc"))
        }
    }

    // MARK: Toolbar

    private var subscribeToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                isSubscribePresented = true
            } label: {
                Label(CupThreadStrings.tr("cupthread.whatsnew.subscribe_button"), systemImage: "envelope")
            }
            .accessibilityHint(CupThreadStrings.tr("cupthread.whatsnew.subscribe_desc"))
        }
    }

    // MARK: Actions

    @MainActor
    private func loadEntries() async {
        isLoading = true
        loadError = nil
        defer {
            isLoading = false
            hasLoadedOnce = true
        }
        do {
            entries = try await client.fetchChangelog()
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - Entry card

struct ChangelogEntryCard: View {
    let entry: ChangelogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            Text(entry.title)
                .font(.subheadline.weight(.semibold))

            if !entry.body.isEmpty {
                MarkdownText(content: entry.body)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !entry.linkedRequests.isEmpty {
                linkedRequestChips
            }
        }
        .requestCard()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var header: some View {
        if entry.versionLabel != nil || entry.publishedAtDate != nil {
            HStack(alignment: .firstTextBaseline) {
                if let version = entry.versionLabel {
                    CapsuleBadge(icon: "tag", text: version, tint: .accentColor)
                        .accessibilityLabel("Version \(version)")
                }
                Spacer(minLength: 8)
                if let date = entry.publishedAtDate {
                    Text(date, format: .dateTime.month(.abbreviated).day().year())
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var linkedRequestChips: some View {
        FlowLayout(spacing: 6) {
            ForEach(entry.linkedRequests) { request in
                CapsuleBadge(icon: "checkmark.circle.fill", text: request.title, tint: .green)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Shipped requests: \(entry.linkedRequests.map(\.title).joined(separator: ", "))")
    }
}

// MARK: - Subscribe footer (card list entry point)

private struct SubscribeFooterCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "envelope")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Get Update Emails")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Be notified when a new version ships.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .requestCard()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Subscribe to update emails")
    }
}

// MARK: - Subscribe sheet

private struct ChangelogSubscribeView: View {
    let client: FeedbackClient
    let userToken: String

    private enum Phase: Equatable {
        case form
        case subscribed(already: Bool)
        case unsubscribed
    }

    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var phase: Phase = .form
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .form:
                    form
                case .subscribed(let already):
                    resultView(
                        icon: "checkmark.circle.fill",
                        tint: .green,
                        title: already ? "You're Already Subscribed" : "You're Subscribed",
                        message: "Update emails will go to \(trimmedEmail)."
                    )
                case .unsubscribed:
                    resultView(
                        icon: "envelope",
                        tint: .secondary,
                        title: "Unsubscribed",
                        message: "You'll no longer receive update emails at \(trimmedEmail)."
                    )
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
                Text("We'll only email you when this app publishes new updates.")
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

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

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
        case .subscribed:
            return isWorking ? "Unsubscribing…" : "Unsubscribe"
        case .unsubscribed:
            return "Done"
        }
    }

    @MainActor
    private func runPrimaryAction() async {
        switch phase {
        case .form:
            await subscribe()
        case .subscribed:
            await unsubscribe()
        case .unsubscribed:
            dismiss()
        }
    }

    @MainActor
    private func subscribe() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let result = try await client.subscribeToChangelog(email: trimmedEmail, userToken: userToken)
            withAnimation(.snappy(duration: 0.3)) {
                phase = .subscribed(already: result.alreadySubscribed)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func unsubscribe() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            _ = try await client.unsubscribeFromChangelog(email: trimmedEmail)
            withAnimation(.snappy(duration: 0.3)) {
                phase = .unsubscribed
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Flow layout

/// Wrapping layout so variable-width chips flow across lines instead of
/// truncating (used for shipped-request badges).
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var size = CGSize.zero
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let item = subview.sizeThatFits(.unspecified)
            if x > 0, x + item.width > maxWidth {
                size.height += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += item.width + spacing
            rowHeight = max(rowHeight, item.height)
            size.width = max(size.width, x - spacing)
        }
        size.height += rowHeight
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var point = CGPoint(x: bounds.minX, y: bounds.minY)
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let item = subview.sizeThatFits(.unspecified)
            if point.x > bounds.minX, point.x + item.width > bounds.maxX {
                point.x = bounds.minX
                point.y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: point, anchor: .topLeading, proposal: .unspecified)
            point.x += item.width + spacing
            rowHeight = max(rowHeight, item.height)
        }
    }
}
