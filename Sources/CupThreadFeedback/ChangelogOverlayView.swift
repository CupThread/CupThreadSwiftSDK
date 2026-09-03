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

    /// Creates the overlay sheet.
    ///
    /// Pass `entries` and `appearance` only when you already fetched them via
    /// ``FeedbackClient/prepareChangelogOverlay(onlyIfUnseen:)``; otherwise the view loads
    /// both on first appearance.
    /// - Parameters:
    ///   - client: The shared ``FeedbackClient``.
    ///   - entries: Pre-fetched changelog entries; `nil` makes the view fetch
    ///     them itself.
    ///   - appearance: Pre-fetched console appearance; `nil` makes the view
    ///     fetch it itself.
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
                if !isLoading && loadError == nil {
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

    @MainActor
    private func load() async {
        if let preparedAppearance {
            appearance = preparedAppearance
        }
        if let preparedEntries {
            entries = preparedEntries
            isLoading = false
            return
        }

        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let config = try await client.fetchAppConfig()
            appearance = config.sdk
            let all = try await client.fetchChangelog()
            entries = Array(all.prefix(config.sdk.changelogOverlay.entryCount))
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func markSeenIfEnabled() {
        guard autoMarkSeen, let first = entries.first else { return }
        client.markChangelogSeen(version: first.id)
        if let versionLabel = first.versionLabel {
            client.markChangelogSeen(version: versionLabel)
        }
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
    /// - Parameter version: The version label (e.g. `"1.2.0"`) or entry ID.
    /// - Returns: `true` if previously recorded as seen.
    public func hasSeenChangelog(version: String) -> Bool {
        let key = "com.cupthread.changelog.seenVersions.\(configuration.appKey)"
        let seen = UserDefaults.standard.stringArray(forKey: key) ?? []
        return seen.contains(version)
    }

    /// Marks the given changelog version or entry ID as seen.
    ///
    /// - Parameter version: The version label or entry ID to record.
    public func markChangelogSeen(version: String) {
        let key = "com.cupthread.changelog.seenVersions.\(configuration.appKey)"
        var seen = UserDefaults.standard.stringArray(forKey: key) ?? []
        if !seen.contains(version) {
            seen.append(version)
            UserDefaults.standard.set(seen, forKey: key)
        }
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
        return await presentPreparedChangelogOverlay(
            client: self,
            entries: prepared.entries,
            appearance: prepared.appearance
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
    ///     overlayEntries = prepared.entries
    ///     showSheet = true
    /// }
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
        let config = try await fetchAppConfig()
        guard config.sdk.features.changelog else { return nil }
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

private final class ResumeBox: @unchecked Sendable {
    var resumed = false
    let continuation: CheckedContinuation<Bool, Never>
    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }
    func finish(_ value: Bool) {
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: value)
    }
}

@MainActor
private func presentPreparedChangelogOverlay(
    client: FeedbackClient,
    entries: [ChangelogEntry],
    appearance: SdkAppearance
) async -> Bool {
    await withCheckedContinuation { continuation in
        let box = ResumeBox(continuation)

        #if canImport(UIKit) && !os(watchOS)
        guard let presenter = topViewController() else {
            box.finish(false)
            return
        }
        let host = UIHostingController(
            rootView: ChangelogOverlayView(
                client: client,
                entries: entries,
                appearance: appearance,
                onPrimary: {
                    presenter.dismiss(animated: true) { box.finish(true) }
                },
                onClose: {
                    presenter.dismiss(animated: true) { box.finish(true) }
                }
            )
            .onDisappear { box.finish(true) }
        )
        #if os(tvOS)
        // .pageSheet is unavailable on tvOS; full-screen default fits the
        // focus-driven layout better anyway.
        presenter.present(host, animated: true)
        #else
        host.modalPresentationStyle = .pageSheet
        presenter.present(host, animated: true)
        #endif
        #elseif os(macOS)
        guard let controller = NSApp.keyWindow?.contentViewController ?? NSApp.windows.first?.contentViewController else {
            box.finish(false)
            return
        }
        let host = NSHostingController(
            rootView: ChangelogOverlayView(
                client: client,
                entries: entries,
                appearance: appearance,
                onPrimary: {
                    controller.dismiss(nil)
                    box.finish(true)
                },
                onClose: {
                    controller.dismiss(nil)
                    box.finish(true)
                }
            )
            .onDisappear { box.finish(true) }
        )
        controller.presentAsSheet(host)
        #else
        box.finish(false)
        #endif
    }
}

#if canImport(UIKit) && !os(watchOS)
@MainActor
private func topViewController(base: UIViewController? = nil) -> UIViewController? {
    let root = base ?? UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .first { $0.isKeyWindow }?
        .rootViewController
    if let nav = root as? UINavigationController {
        return topViewController(base: nav.visibleViewController)
    }
    if let tab = root as? UITabBarController {
        return topViewController(base: tab.selectedViewController)
    }
    if let presented = root?.presentedViewController {
        return topViewController(base: presented)
    }
    return root
}
#endif
