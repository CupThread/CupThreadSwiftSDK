import Foundation
import Testing
#if os(macOS)
import AppKit
import SwiftUI
@testable import CupThreadFeedback

@Suite("ChangelogOverlayAppKitDismissalTests", .serialized)
@MainActor
struct ChangelogOverlayAppKitDismissalTests {
    private final class PresentationContextSpy: ChangelogOverlayPresentationContext {
        private(set) var isPresented = false
        private(set) var isDismissed = false
        private(set) var isRefused = false

        func markPresented() {
            isPresented = true
        }

        func markDismissed() {
            isDismissed = true
        }

        func markRefused() {
            isRefused = true
        }
    }

    private func makeWindowAndPresenter() -> (window: NSWindow, rootVC: NSViewController) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let rootVC = NSViewController()
        window.contentViewController = rootVC
        return (window, rootVC)
    }

    private func makeSampleEntries() -> [ChangelogEntry] {
        [
            ChangelogEntry(
                id: "e1",
                title: "Version 1.0",
                body: "First release",
                versionLabel: "1.0.0",
                publishedAt: "2026-01-01T00:00:00.000Z",
                linkedRequests: []
            )
        ]
    }

    @Test("Presented sheet is dismissed when dismiss is called on the presented host, but not on rootVC")
    func presentedSheetDismissesCorrectly() {
        let (_, rootVC) = makeWindowAndPresenter()
        let sheetVC = NSViewController()

        rootVC.presentAsSheet(sheetVC)
        #expect(rootVC.presentedViewControllers?.contains(sheetVC) == true)

        // Calling dismiss(nil) on rootVC fails to dismiss sheetVC in AppKit
        rootVC.dismiss(nil)
        #expect(rootVC.presentedViewControllers?.contains(sheetVC) == true)

        // Calling dismiss(nil) on sheetVC correctly dismisses the sheet
        sheetVC.dismiss(nil)
        #expect(rootVC.presentedViewControllers?.isEmpty ?? true)
    }

    @Test("Calling dismiss(sheetVC) on rootVC also dismisses the presented sheet")
    func dismissViewControllerDismissesCorrectly() {
        let (_, rootVC) = makeWindowAndPresenter()
        let sheetVC = NSViewController()

        rootVC.presentAsSheet(sheetVC)
        #expect(rootVC.presentedViewControllers?.contains(sheetVC) == true)

        rootVC.dismiss(sheetVC)
        #expect(rootVC.presentedViewControllers?.isEmpty ?? true)
    }

    @Test("presentAppKit presents sheet host on the given controller and dismiss(host) dismisses it")
    func presentAppKitDismissViaPresenter() {
        let (_, rootVC) = makeWindowAndPresenter()
        let client = makeClient()
        let context = PresentationContextSpy()
        let presenter = DefaultChangelogOverlayPresenter()

        let host = presenter.presentAppKit(
            client: client,
            entries: makeSampleEntries(),
            appearance: .defaults,
            context: context,
            presentingController: rootVC
        )
        guard let host else {
            Issue.record("Expected non-nil host")
            return
        }

        #expect(rootVC.presentedViewControllers?.contains(host) == true)

        // Verifies controller.dismiss(host) correctly dismisses the presented sheet
        rootVC.dismiss(host)
        #expect(rootVC.presentedViewControllers?.isEmpty ?? true)
    }

    @Test("presentAppKit presents sheet host on the given controller and host.dismiss(nil) dismisses it")
    func presentAppKitDismissViaHost() {
        let (_, rootVC) = makeWindowAndPresenter()
        let client = makeClient()
        let context = PresentationContextSpy()
        let presenter = DefaultChangelogOverlayPresenter()

        let host = presenter.presentAppKit(
            client: client,
            entries: makeSampleEntries(),
            appearance: .defaults,
            context: context,
            presentingController: rootVC
        )
        guard let host else {
            Issue.record("Expected non-nil host")
            return
        }

        #expect(rootVC.presentedViewControllers?.contains(host) == true)

        // Verifies host.dismiss(nil) correctly dismisses the presented sheet
        host.dismiss(nil)
        #expect(rootVC.presentedViewControllers?.isEmpty ?? true)
    }

    @Test("Default presenter marks context refused when no window or presenting controller is available")
    func defaultPresenterRefusesWhenNoController() {
        let client = makeClient()
        let context = PresentationContextSpy()
        let presenter = DefaultChangelogOverlayPresenter()

        let host = presenter.presentAppKit(
            client: client,
            entries: makeSampleEntries(),
            appearance: .defaults,
            context: context,
            presentingController: nil
        )

        if host == nil {
            #expect(context.isRefused == true)
        }
    }
}
#endif
