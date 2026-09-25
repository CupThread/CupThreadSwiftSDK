import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Overlay view

/// Sheet that shows the latest published changelog entries using console-configured copy.
///
/// Host apps typically present this after launch via `FeedbackClient.presentLatestChangelog()`
/// or the SwiftUI `.changelogOverlay(client:isPresented:)` modifier.
public struct ChangelogOverlayView: View {
    public let client: FeedbackClient
    public var autoMarkSeen: Bool
    public var onPrimary: () -> Void
    public var onClose: () -> Void

    private let preparedEntries: [ChangelogEntry]?
    private let preparedAppearance: SdkAppearance?

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [ChangelogEntry] = []
    @State private var appearance: SdkAppearance = .defaults
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var featureDisabled = false
    @State private var hasMarkedSeen = false

    /// Creates the overlay sheet.
    ///
    /// With no pre-fetched content the view loads everything on first
    /// appearance: it fetches the console configuration and newest entries
    /// itself and enforces the console's `sdk.features.changelog` switch —
    /// when the surface is off, no changelog request is made and the sheet
    /// shows an "unavailable" placeholder.
    ///
    /// When you already fetched content via
    /// ``FeedbackClient/prepareChangelogOverlay(onlyIfUnseen:)``, prefer
    /// ``init(client:prepared:autoMarkSeen:onPrimary:onClose:)``, which keeps
    /// entries and appearance paired. Passing `entries` and `appearance`
    /// together renders the sheet without any network request. Passing
    /// `entries` without `appearance` — easy to do when destructuring the
    /// prepare result — still honors the console: the view fetches the
    /// configuration for theming before revealing the content, so the title,
    /// buttons, and theme keep matching the console.
    /// - Parameters:
    ///   - client: The shared ``FeedbackClient``.
    ///   - entries: Pre-fetched changelog entries; `nil` makes the view fetch
    ///     them itself.
    ///   - appearance: Pre-fetched console appearance; `nil` makes the view
    ///     resolve it from the console configuration (falling back to
    ///     ``SdkAppearance/defaults`` when that fails).
    ///   - autoMarkSeen: Automatically marks the displayed version as seen on dismissal.
    ///   - onPrimary: Called when the user taps the console-configured primary
    ///     button; the sheet dismisses afterwards.
    ///   - onClose: Called when the user taps the close button; the sheet
    ///     dismisses afterwards.
    public init(
        client: FeedbackClient,
        entries: [ChangelogEntry]? = nil,
        appearance: SdkAppearance? = nil,
        autoMarkSeen: Bool = true,
        onPrimary: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {}
    ) {
        self.client = client
        self.preparedEntries = entries
        self.preparedAppearance = appearance
        self.autoMarkSeen = autoMarkSeen
        self.onPrimary = onPrimary
        self.onClose = onClose
    }

    /// Creates the overlay sheet from a
    /// ``FeedbackClient/prepareChangelogOverlay(onlyIfUnseen:)`` result.
    ///
    /// Equivalent to passing `prepared?.entries` and `prepared?.appearance`
    /// to ``init(client:entries:appearance:autoMarkSeen:onPrimary:onClose:)``,
    /// but the pairing cannot be lost by destructuring the tuple — the
    /// console theme and copy always apply to the prepared entries. Passing
    /// `nil` (including a `nil` prepare result, which means the overlay
    /// should stay hidden) makes the view load everything itself.
    public init(
        client: FeedbackClient,
        prepared: (entries: [ChangelogEntry], appearance: SdkAppearance)?,
        autoMarkSeen: Bool = true,
        onPrimary: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {}
    ) {
        self.init(
            client: client,
            entries: prepared?.entries,
            appearance: prepared?.appearance,
            autoMarkSeen: autoMarkSeen,
            onPrimary: onPrimary,
            onClose: onClose
        )
    }

    private var overlay: ChangelogOverlayConfig { appearance.changelogOverlay }

    public var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    LoadErrorView(message: loadError) {
                        await load()
                    }
                } else if featureDisabled {
                    FeatureDisabledView(feature: .changelog)
                } else {
                    content
                }
            }
            .navigationTitle(overlay.title)
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(overlay.closeButton) { close() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !isLoading && loadError == nil && !featureDisabled {
                    Button(overlay.primaryButton) { primary() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
            }
        }
        .tint(appearance.theme.accentColor)
        .preferredColorScheme(appearance.theme.preferredColorScheme)
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
        .task { await load() }
        .safeWebOpenURL()
        .onDisappear { markSeenIfEnabled() }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !overlay.subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(overlay.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if entries.isEmpty {
                    ContentUnavailableView {
                        Label(CupThreadStrings.tr("cupthread.whatsnew.no_updates_title"), systemImage: "sparkles")
                    } description: {
                        Text(CupThreadStrings.tr("cupthread.whatsnew.no_updates_desc"))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                } else {
                    ForEach(entries) { entry in
                        ChangelogEntryCard(entry: entry)
                    }
                }
            }
            .padding(16)
        }
    }

    /// Content fetched by the overlay's self-loading path (direct init with
    /// `entries: nil`, or the `.changelogOverlay` modifier).
    enum SelfLoadedContent: Equatable {
        /// The console turned the changelog surface off; no entries were
        /// fetched and the overlay shows the shared disabled placeholder.
        case featureDisabled(SdkAppearance)
        /// Newest entries capped by the console's entry count, plus the
        /// console appearance.
        case entries([ChangelogEntry], appearance: SdkAppearance)
        /// A network or decoding failure, carrying the user-facing message.
        case failed(String)
    }

    /// Fetches config and newest entries for the self-loading paths.
    ///
    /// Enforces the console's `sdk.features.changelog` switch the same way
    /// ``FeedbackClient/prepareChangelogOverlay(onlyIfUnseen:)`` does: when
    /// the surface is off the changelog request is never made.
    ///
    /// Returns `nil` when the fetch was cancelled (the overlay closed or the
    /// presenting task was superseded mid-load) — a cancelled load never
    /// reached a verdict, so callers must keep their current state instead
    /// of reporting a failure.
    static func fetchSelfLoadedContent(in client: FeedbackClient) async -> SelfLoadedContent? {
        do {
            let config = try await client.cachedAppConfig()
            guard config.sdk.features.isEnabled(.changelog) else {
                return .featureDisabled(config.sdk)
            }
            let all = try await client.fetchChangelog()
            return .entries(
                Array(all.prefix(config.sdk.changelogOverlay.entryCount)),
                appearance: config.sdk
            )
        } catch {
            guard !error.isSdkCancellation else { return nil }
            return .failed(FriendlyError.message(for: error))
        }
    }

    /// How the load path resolves content from the init-time prepared values.
    ///
    /// Truth table (`entries`, `appearance`) → plan:
    /// `(set, set)` → `.showPrepared(needsConfigFetch: false)`;
    /// `(set, nil)` → `.showPrepared(needsConfigFetch: true)`;
    /// `(nil, anything)` → `.fetchRemote`.
    enum LoadPlan: Equatable {
        /// Pre-fetched entries are shown directly. When `needsConfigFetch` is
        /// `true`, the host passed `entries` without `appearance`, so the load
        /// path still resolves the console appearance (falling back to the
        /// last-good cache, then ``SdkAppearance/defaults``) before revealing
        /// the content.
        case showPrepared(needsConfigFetch: Bool)
        /// No prepared entries; the view fetches config and entries itself
        /// via ``fetchSelfLoadedContent(in:)``.
        case fetchRemote
    }

    /// Decides the load plan for the given prepared values: entries without
    /// an appearance still honor the console configuration; without prepared
    /// entries the view self-loads.
    static func loadPlan(
        entries: [ChangelogEntry]?,
        appearance: SdkAppearance?
    ) -> LoadPlan {
        guard entries != nil else { return .fetchRemote }
        return .showPrepared(needsConfigFetch: appearance == nil)
    }

    /// The plan this view's `load()` follows for its init-time values.
    var preparedLoadPlan: LoadPlan {
        Self.loadPlan(entries: preparedEntries, appearance: preparedAppearance)
    }

    /// Resolves the console appearance for hosts that passed `entries`
    /// without `appearance`.
    ///
    /// Mirrors the SDK's shared configuration semantics (``CupThreadTheme``):
    /// the fetched appearance on success, the last-good cached appearance
    /// when the fetch fails, and ``SdkAppearance/defaults`` when there is no
    /// cached value either.
    static func resolveFallbackAppearance(in client: FeedbackClient) async -> SdkAppearance {
        guard let config = try? await client.cachedAppConfig() else {
            return client.configStore.lastGoodAppearance() ?? .defaults
        }
        return config.sdk
    }

    @MainActor
    private func load() async {
        if let preparedAppearance {
            appearance = preparedAppearance
        }
        switch preparedLoadPlan {
        case .showPrepared(let needsConfigFetch):
            if let preparedEntries {
                entries = preparedEntries
            }
            if needsConfigFetch {
                // Entries were pre-fetched without an appearance: honor the
                // console theme and copy before revealing the sheet. The
                // spinner from the initial state stays up until this resolves.
                defer { isLoading = false }
                appearance = await Self.resolveFallbackAppearance(in: client)
            } else {
                isLoading = false
            }
        case .fetchRemote:
            isLoading = true
            loadError = nil
            featureDisabled = false
            defer { isLoading = false }
            switch await Self.fetchSelfLoadedContent(in: client) {
            case .entries(let loaded, let loadedAppearance):
                appearance = loadedAppearance
                entries = loaded
            case .featureDisabled(let loadedAppearance):
                appearance = loadedAppearance
                featureDisabled = true
            case .failed(let message):
                loadError = message
            case nil:
                // Cancelled mid-fetch: leave the prepared state alone.
                break
            }
        }
    }

    private func markSeenIfEnabled() {
        guard autoMarkSeen, !hasMarkedSeen, let first = entries.first else { return }
        hasMarkedSeen = true
        client.markChangelogSeen(id: first.id, versionLabel: first.versionLabel)
    }

    private func close() {
        markSeenIfEnabled()
        onClose()
        dismiss()
    }

    private func primary() {
        markSeenIfEnabled()
        onPrimary()
        dismiss()
    }
}

// MARK: - SwiftUI modifier

private struct ChangelogOverlayModifier: ViewModifier {
    let client: FeedbackClient
    var autoMarkSeen: Bool
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            ChangelogOverlayView(
                client: client,
                autoMarkSeen: autoMarkSeen,
                onPrimary: { isPresented = false },
                onClose: { isPresented = false }
            )
        }
    }
}

extension View {
    /// Presents the console-configured latest-changelog overlay as a sheet.
    ///
    /// The sheet fetches the app configuration and newest entries when shown,
    /// so the copy (title, buttons, entry count) always matches the console.
    /// When the console turns the changelog surface off, the sheet shows an
    /// "unavailable" placeholder instead of fetching entries.
    ///
    /// ```swift
    /// ContentView()
    ///     .task { showWhatsNew = true }
    ///     .changelogOverlay(client: client, isPresented: $showWhatsNew)
    /// ```
    ///
    /// - Parameters:
    ///   - client: The shared ``FeedbackClient``.
    ///   - isPresented: Binding controlling the sheet; set it to `true` to
    ///     show the overlay. Dismissal from inside the sheet writes `false`.
    ///   - autoMarkSeen: Automatically marks the displayed version as seen on dismissal.
    /// - Returns: A view that presents ``ChangelogOverlayView`` when triggered.
    public func changelogOverlay(
        client: FeedbackClient,
        isPresented: Binding<Bool>,
        autoMarkSeen: Bool = true
    ) -> some View {
        modifier(ChangelogOverlayModifier(client: client, autoMarkSeen: autoMarkSeen, isPresented: isPresented))
    }
}

// MARK: - Programmatic presentation

extension FeedbackClient {
    /// Checks whether the user has already seen the changelog overlay for the given version or entry ID.
    ///
    /// Seen versions are tracked in a thread-safe store bounded to the newest 64 releases
    /// for this app key.
    ///
    /// - Parameter version: The version label (e.g. `"1.2.0"`) or entry ID.
    /// - Returns: `true` if previously recorded as seen.
    public func hasSeenChangelog(version: String) -> Bool {
        ChangelogSeenStore.shared(for: configuration.appKey).hasSeen(version)
    }

    /// Marks the given changelog version or entry ID as seen.
    ///
    /// Persists the version label or entry ID in a thread-safe store scoped to this app key,
    /// bounded to the newest 64 releases (older entries are automatically pruned).
    ///
    /// - Parameter version: The version label or entry ID to record.
    public func markChangelogSeen(version: String) {
        ChangelogSeenStore.shared(for: configuration.appKey).markSeen(version)
    }

    /// Marks both a changelog entry ID and an optional version label as seen in a single atomic pass.
    ///
    /// Persists the tokens in a thread-safe store scoped to this app key, executing capacity
    /// truncation and persistence in a single disk write.
    ///
    /// - Parameters:
    ///   - id: The entry ID to record.
    ///   - versionLabel: An optional version label (e.g. `"1.2.0"`) to record.
    public func markChangelogSeen(id: String, versionLabel: String?) {
        ChangelogSeenStore.shared(for: configuration.appKey).markSeen(id: id, versionLabel: versionLabel)
    }

    /// Presents the latest changelog overlay using copy and limits from the console.
    ///
    /// Returns `false` when changelog is hidden, there is no host window to present
    /// from, or there are no published entries. Throws if the network request fails.
    ///
    /// Use ``prepareChangelogOverlay(onlyIfUnseen:)`` plus ``ChangelogOverlayView`` instead
    /// when you need control over where and how the sheet appears.
    /// - Parameter onlyIfUnseen: When `true`, suppresses presentation if the newest
    ///   version has already been marked as seen via ``hasSeenChangelog(version:)``.
    /// - Returns: Whether the overlay was actually presented.
    /// - Throws: The same errors as ``fetchChangelog()`` and ``fetchAppConfig()``
    ///   when either network call fails.
    @MainActor
    @discardableResult
    public func presentLatestChangelog(onlyIfUnseen: Bool = false) async throws -> Bool {
        guard let prepared = try await prepareChangelogOverlay(onlyIfUnseen: onlyIfUnseen) else { return false }
        let presenter = overlayPresenter ?? DefaultChangelogOverlayPresenter()
        return await presentPreparedChangelogOverlay(
            client: self,
            entries: prepared.entries,
            appearance: prepared.appearance,
            presenter: presenter
        )
    }

    /// Fetches overlay configuration and the newest published entries.
    /// Returns `nil` when the console hid changelog, nothing has been published,
    /// or when `onlyIfUnseen` is true and the latest release was already seen.
    ///
    /// Pair the result with ``ChangelogOverlayView`` for custom presentation:
    ///
    /// ```swift
    /// if let prepared = try await client.prepareChangelogOverlay(onlyIfUnseen: true) {
    ///     preparedOverlay = prepared
    ///     showSheet = true
    /// }
    /// // …in the sheet content, entries and appearance stay paired:
    /// ChangelogOverlayView(client: client, prepared: preparedOverlay)
    /// ```
    ///
    /// - Parameter onlyIfUnseen: When `true`, returns `nil` if the newest entry
    ///   was already marked as seen.
    /// - Returns: Newest entries (capped by the console's entry count) plus
    ///   the appearance, or `nil` when the overlay should stay hidden.
    /// - Throws: The same errors as ``fetchChangelog()`` and ``fetchAppConfig()``
    ///   when either network call fails.
    public func prepareChangelogOverlay(
        onlyIfUnseen: Bool = false
    ) async throws -> (entries: [ChangelogEntry], appearance: SdkAppearance)? {
        let config = try await cachedAppConfig()
        guard config.sdk.features.isEnabled(.changelog) else { return nil }
        let all = try await fetchChangelog()
        let entries = Array(all.prefix(config.sdk.changelogOverlay.entryCount))
        guard let latest = entries.first else { return nil }

        if onlyIfUnseen {
            let isSeen = hasSeenChangelog(version: latest.id) ||
                (latest.versionLabel.map { hasSeenChangelog(version: $0) } ?? false)
            if isSeen { return nil }
        }

        return (entries, config.sdk)
    }
}
