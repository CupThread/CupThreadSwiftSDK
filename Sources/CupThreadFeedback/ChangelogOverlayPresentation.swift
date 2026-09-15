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
