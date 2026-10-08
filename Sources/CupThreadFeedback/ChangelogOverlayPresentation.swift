import SwiftUI
#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Presentation continuation box

final class ResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    let continuation: CheckedContinuation<Bool, Never>

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func finish(_ value: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return false }
        resumed = true
        continuation.resume(returning: value)
        return true
    }
}

// MARK: - Presentation context

@MainActor
protocol ChangelogOverlayPresentationContext: AnyObject, Sendable {
    var isPresented: Bool { get }
    func markPresented()
    func markDismissed()
    func markRefused()
}

@MainActor
final class DefaultPresentationContext: ChangelogOverlayPresentationContext {
    private let box: ResumeBox
    private(set) var isPresented = false
    var watchdogTask: Task<Void, Never>?

    init(box: ResumeBox) {
        self.box = box
    }

    func markPresented() {
        isPresented = true
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    func markDismissed() {
        isPresented = true
        watchdogTask?.cancel()
        watchdogTask = nil
        box.finish(true)
    }

    func markRefused() {
        watchdogTask?.cancel()
        watchdogTask = nil
        box.finish(false)
    }
}

// MARK: - Presenter seam

@MainActor
protocol ChangelogOverlayPresenter: Sendable {
    func present(
        client: FeedbackClient,
        entries: [ChangelogEntry],
        appearance: SdkAppearance,
        context: ChangelogOverlayPresentationContext
    ) async
}

extension ChangelogOverlayPresenter {
    @MainActor
    func present(
        client: FeedbackClient,
        entries: [ChangelogEntry],
        appearance: SdkAppearance,
        watchdogTimeout: Duration = .seconds(3)
    ) async -> Bool {
        await presentPreparedChangelogOverlay(
            client: client,
            entries: entries,
            appearance: appearance,
            presenter: self,
            watchdogTimeout: watchdogTimeout
        )
    }
}

@MainActor
func presentPreparedChangelogOverlay(
    client: FeedbackClient,
    entries: [ChangelogEntry],
    appearance: SdkAppearance,
    presenter: any ChangelogOverlayPresenter = DefaultChangelogOverlayPresenter(),
    watchdogTimeout: Duration = .seconds(3)
) async -> Bool {
    await withCheckedContinuation { continuation in
        let box = ResumeBox(continuation)
        let context = DefaultPresentationContext(box: box)

        let watchdogTask = Task { @MainActor in
            try? await Task.sleep(for: watchdogTimeout)
            guard !Task.isCancelled else { return }
            if !context.isPresented {
                context.markRefused()
            }
        }
        context.watchdogTask = watchdogTask

        Task { @MainActor in
            await presenter.present(
                client: client,
                entries: entries,
                appearance: appearance,
                context: context
            )
        }
    }
}

// MARK: - Default platform presenter

@MainActor
struct DefaultChangelogOverlayPresenter: ChangelogOverlayPresenter {
    func present(
        client: FeedbackClient,
        entries: [ChangelogEntry],
        appearance: SdkAppearance,
        context: ChangelogOverlayPresentationContext
    ) async {
        #if canImport(UIKit) && !os(watchOS)
        await presentUIKit(client: client, entries: entries, appearance: appearance, context: context)
        #elseif os(macOS)
        presentAppKit(client: client, entries: entries, appearance: appearance, context: context)
        #else
        context.markRefused()
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
    private func presentUIKit(
        client: FeedbackClient,
        entries: [ChangelogEntry],
        appearance: SdkAppearance,
        context: ChangelogOverlayPresentationContext
    ) async {
        guard let presenter = await resolvePresenter() else {
            context.markRefused()
            return
        }

        guard presenter.view.window != nil,
              !presenter.isBeingPresented,
              !presenter.isBeingDismissed else {
            context.markRefused()
            return
        }

        let host = UIHostingController(
            rootView: ChangelogOverlayView(
                client: client,
                entries: entries,
                appearance: appearance,
                onPrimary: {
                    presenter.dismiss(animated: true) { context.markDismissed() }
                },
                onClose: {
                    presenter.dismiss(animated: true) { context.markDismissed() }
                }
            )
            .onAppear { context.markPresented() }
            .onDisappear { context.markDismissed() }
        )

        #if os(tvOS)
        presenter.present(host, animated: true) { [weak host, weak context] in
            if host?.presentingViewController == nil {
                context?.markRefused()
            }
        }
        #else
        host.modalPresentationStyle = .pageSheet
        presenter.present(host, animated: true) { [weak host, weak context] in
            if host?.presentingViewController == nil {
                context?.markRefused()
            }
        }
        #endif
    }
    #endif

    #if os(macOS)
    private func presentAppKit(
        client: FeedbackClient,
        entries: [ChangelogEntry],
        appearance: SdkAppearance,
        context: ChangelogOverlayPresentationContext
    ) {
        guard let controller = NSApp.keyWindow?.contentViewController ?? NSApp.windows.first?.contentViewController else {
            context.markRefused()
            return
        }
        let host = NSHostingController(
            rootView: ChangelogOverlayView(
                client: client,
                entries: entries,
                appearance: appearance,
                onPrimary: {
                    controller.dismiss(nil)
                    context.markDismissed()
                },
                onClose: {
                    controller.dismiss(nil)
                    context.markDismissed()
                }
            )
            .onAppear { context.markPresented() }
            .onDisappear { context.markDismissed() }
        )
        controller.presentAsSheet(host)
    }
    #endif
}

// MARK: - View controller resolution

#if canImport(UIKit) && !os(watchOS)
@MainActor
private func resolvePresenter() async -> UIViewController? {
    for _ in 0..<4 {
        guard let presenter = topViewController() else { return nil }
        if presenter.isBeingPresented || presenter.isBeingDismissed {
            try? await Task.sleep(nanoseconds: 50_000_000)
        } else {
            return presenter
        }
    }
    return topViewController()
}

@MainActor
private func topViewController(base: UIViewController? = nil) -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let root = base ?? scenes
        .flatMap(\.windows)
        .first { $0.isKeyWindow }?
        .rootViewController
        ?? scenes.flatMap(\.windows).first?.rootViewController
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
    /// Fetches the app configuration and a single page of newest entries sized
    /// to the console-configured entry count, then displays the overlay using the
    /// configured presenter.
    /// Returns `false` when changelog is hidden, sign-in is required but no
    /// usable bearer token can be presented, there is no host window to present
    /// from, or there are no published entries. Throws if the network request fails.
    ///
    /// Use ``prepareChangelogOverlay(onlyIfUnseen:)`` plus ``ChangelogOverlayView`` instead
    /// when you need control over where and how the sheet appears.
    /// - Parameter onlyIfUnseen: When `true`, suppresses presentation if the newest
    ///   version has already been marked as seen via ``hasSeenChangelog(version:)``.
    /// - Returns: Whether the overlay was actually presented.
    /// - Throws: The same errors as ``fetchChangelog(limit:cursor:)`` and ``fetchAppConfig()``
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
    /// Returns `nil` when the console hid changelog, sign-in is required but
    /// the client cannot produce a bearer token (or the server rejected the
    /// one it produced with `401 authentication_required`), nothing has been
    /// published, or when `onlyIfUnseen` is true and the latest release was
    /// already seen.
    ///
    /// Fetches a single page of newest entries sized to the console-configured
    /// `entryCount` (clamped to 1...10) rather than walking full changelog history.
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
    /// The anonymous-access preflight resolves the bearer token on every call,
    /// so a sign-in between two launches is picked up (issue #297); a
    /// signed-out user on a sign-in-required board gets `nil` instead of a
    /// guaranteed-to-fail fetch.
    /// - Parameter onlyIfUnseen: When `true`, returns `nil` if the newest entry
    ///   was already marked as seen.
    /// - Returns: Newest entries (capped by the console's entry count) plus
    ///   the appearance, or `nil` when the overlay should stay hidden.
    /// - Throws: The same errors as ``fetchChangelog(limit:cursor:)`` and ``fetchAppConfig()``
    ///   when either network call fails.
    public func prepareChangelogOverlay(
        onlyIfUnseen: Bool = false
    ) async throws -> (entries: [ChangelogEntry], appearance: SdkAppearance)? {
        let config = try await cachedAppConfig()
        guard config.sdk.features.isEnabled(.changelog) else { return nil }
        guard changelogLoadPlan(
            config: config,
            supportsAuthentication: await resolveAuthenticatedAccess()
        ) == .load else { return nil }
        let limit = max(1, config.sdk.changelogOverlay.entryCount)
        let page: ListChangelogResult
        do {
            page = try await fetchChangelog(limit: limit)
        } catch {
            // The preflight resolved a token but the server still answered
            // 401 (e.g. it expired between the check and the send): the
            // overlay stays hidden, exactly as for a signed-out user.
            if isSdkPermissionRejection(error) { return nil }
            throw error
        }
        let entries = Array(page.entries.prefix(config.sdk.changelogOverlay.entryCount))
        guard let latest = entries.first else { return nil }

        if onlyIfUnseen {
            let isSeen = hasSeenChangelog(version: latest.id) ||
                (latest.versionLabel.map { hasSeenChangelog(version: $0) } ?? false)
            if isSeen { return nil }
        }

        return (entries, config.sdk)
    }
}
