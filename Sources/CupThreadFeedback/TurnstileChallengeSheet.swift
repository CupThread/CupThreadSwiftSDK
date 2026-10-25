#if canImport(WebKit) && !os(tvOS)
import SwiftUI
import WebKit

// MARK: - In-SDK human verification (#53 Phase 2)

/// A sheet that presents the portal's hosted Cloudflare Turnstile challenge
/// and hands back the minted token.
///
/// Present it after an intake call throws
/// ``FeedbackClientError/turnstileRequired(message:requestId:)`` and
/// ``FeedbackClient/turnstileChallengePresentation(for:config:theme:locale:)``
/// returns a presentation, then resubmit with the token through
/// ``FeedbackClient/submit(_:userToken:turnstileToken:)`` or
/// ``FeedbackClient/submitFeatureRequest(_:userToken:turnstileToken:)``:
///
/// ```swift
/// @State private var presentation: TurnstileChallengePresentation?
///
/// // ...
/// .sheet(item: $presentation) { challenge in
///     TurnstileChallengeSheet(
///         challengeURL: challenge.url,
///         onVerified: { token in
///             presentation = nil
///             Task { await resubmit(turnstileToken: token) }
///         },
///         onCancel: { presentation = nil }
///     )
/// }
/// ```
///
/// The view is a thin `WKWebView` host: the hosted page renders the widget
/// with the `(action, cdata)` binding on the query string and posts its
/// outcome to the `turnstileBridge` message handler. Tokens are single-use
/// and valid for 300 seconds, so each gated call opens its own challenge.
/// Cancelling or failing leaves the caller's draft untouched — the sheet
/// owns no submission state. Interactive dismissal is disabled: a swipe-down
/// would close the sheet without answering the challenge, so Cancel is the
/// only exit until the widget reports an outcome (#539).
///
/// The WebKit-backed sheet is unavailable on tvOS, which has no WebKit:
/// token-gated intake there needs a host-supplied `turnstileTokenProvider`.
public struct TurnstileChallengeSheet: View {
    /// What the sheet is showing. Internal so view-level tests can assert it.
    enum Phase: Equatable {
        /// The page is loading or the widget is minting; a spinner covers it.
        case loading
        /// The page failed to load, the widget reported an error, or the
        /// token expired — the overlay offers a fresh attempt.
        case failed
        /// A token was minted and handed to `onVerified`; the sheet dismisses.
        case verified
    }

    let challengeURL: URL
    let onVerified: (String) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading
    @State private var reloadID = UUID()

    /// Creates a challenge sheet for an already-resolved page URL.
    /// - Parameters:
    ///   - challengeURL: The hosted page URL, normally from
    ///     ``FeedbackClient/turnstileChallengePresentation(for:config:theme:locale:)``.
    ///   - onVerified: Receives the single-use token. Submit again with it
    ///     immediately; tokens expire after 300 seconds.
    ///   - onCancel: Called when the user dismisses without verifying. Leave
    ///     the caller's draft intact.
    public init(
        challengeURL: URL,
        onVerified: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.challengeURL = challengeURL
        self.onVerified = onVerified
        self.onCancel = onCancel
    }

    /// The visible phase, for view-level tests.
    var currentPhase: Phase { phase }

    public var body: some View {
        NavigationStack {
            ZStack {
                TurnstileWebView(
                    url: challengeURL,
                    reloadID: reloadID,
                    onMessage: handle,
                    onLoadFailure: { phase = .failed }
                )
                .accessibilityIdentifier("cupthread.turnstile.webview")

                switch phase {
                case .loading:
                    ProgressView()
                        .controlSize(.large)
                        .accessibilityIdentifier("cupthread.turnstile.challenge_progress")
                case .failed:
                    failureOverlay
                case .verified:
                    EmptyView()
                }
            }
            .navigationTitle(CupThreadStrings.tr("cupthread.turnstile.challenge_title"))
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(CupThreadStrings.tr("cupthread.common.cancel")) {
                        onCancel()
                        dismiss()
                    }
                    .accessibilityIdentifier("cupthread.turnstile.challenge_cancel")
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        // The caller's gated work (a draft, a spooled photo) is only settled
        // through Verified or Cancel, so a swipe-down must not leave it
        // stranded. Presenters that chain `onDismiss` still get the safety
        // net for host-driven teardown (#539).
        .interactiveDismissDisabled()
        .task(id: reloadID) {
            // A cold widget mint measured ~8–10 s; give the page and Cloudflare
            // ample time, then fail visibly instead of spinning forever when a
            // bridge message never arrives (offline, blocked script, hung widget).
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled, phase == .loading else { return }
            phase = .failed
        }
    }

    private var failureOverlay: some View {
        VStack(spacing: 12) {
            Text(CupThreadStrings.tr("cupthread.turnstile.challenge_failed"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(CupThreadStrings.tr("cupthread.error.try_again")) {
                phase = .loading
                reloadID = UUID()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("cupthread.turnstile.challenge_retry")
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(24)
    }

    private func handle(_ message: TurnstileBridgeMessage) {
        switch message {
        case .token(let token):
            phase = .verified
            onVerified(token)
            dismiss()
        case .failure, .expired:
            phase = .failed
        }
    }
}

// MARK: - Web view host

#if os(macOS)
private typealias TurnstileNativeViewRepresentable = NSViewRepresentable
#else
private typealias TurnstileNativeViewRepresentable = UIViewRepresentable
#endif

/// Loads the hosted challenge page and forwards its `turnstileBridge`
/// messages. Main-frame navigation is pinned to the page's origin; the
/// widget's own iframe on `challenges.cloudflare.com` stays free to load.
/// Inbound bridge messages are accepted only from the page's main frame on
/// the page's origin (`TurnstileBridgePolicy`); anything else is dropped.
private struct TurnstileWebView: TurnstileNativeViewRepresentable {
    let url: URL
    let reloadID: UUID
    let onMessage: (TurnstileBridgeMessage) -> Void
    let onLoadFailure: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(challengeURL: url, onMessage: onMessage, onLoadFailure: onLoadFailure)
    }

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView {
        makeWebView(context: context)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        reloadIfNeeded(webView, context: context)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        dismantle(webView)
    }
    #else
    func makeUIView(context: Context) -> WKWebView {
        makeWebView(context: context)
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        reloadIfNeeded(webView, context: context)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        dismantle(webView)
    }
    #endif

    private func makeWebView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // The persistent store keeps the browser fingerprint Cloudflare's
        // challenge expects; ephemeral stores trip its bot heuristics.
        configuration.websiteDataStore = .default()
        configuration.userContentController.add(context.coordinator, name: Coordinator.bridgeName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        #if os(iOS) || os(visionOS)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        #endif
        context.coordinator.loadedReloadID = reloadID
        webView.load(URLRequest(url: url))
        return webView
    }

    private func reloadIfNeeded(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedReloadID != reloadID else { return }
        context.coordinator.loadedReloadID = reloadID
        webView.load(URLRequest(url: url))
    }

    private static func dismantle(_ webView: WKWebView) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.bridgeName)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let bridgeName = "turnstileBridge"

        private let challengeURL: URL
        private let onMessage: (TurnstileBridgeMessage) -> Void
        private let onLoadFailure: () -> Void
        var loadedReloadID: UUID?

        init(
            challengeURL: URL,
            onMessage: @escaping (TurnstileBridgeMessage) -> Void,
            onLoadFailure: @escaping () -> Void
        ) {
            self.challengeURL = challengeURL
            self.onMessage = onMessage
            self.onLoadFailure = onLoadFailure
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            // The content controller delivers messages from every frame;
            // only the challenge page's main frame may post into the bridge
            // (#566, see `TurnstileBridgePolicy`).
            guard message.name == Self.bridgeName,
                  TurnstileBridgePolicy.acceptsBridgeMessage(
                      isMainFrame: message.frameInfo.isMainFrame,
                      originProtocol: message.frameInfo.securityOrigin.protocol,
                      originHost: message.frameInfo.securityOrigin.host,
                      originPort: message.frameInfo.securityOrigin.port,
                      challengeURL: challengeURL
                  ),
                  let parsed = TurnstileBridgeMessage.parse(message.body) else {
                return
            }
            onMessage(parsed)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            TurnstileNavigationPolicy.isAllowed(
                isMainFrame: navigationAction.targetFrame?.isMainFrame,
                requestURL: navigationAction.request.url,
                challengeURL: challengeURL
            ) ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onLoadFailure()
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            onLoadFailure()
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onLoadFailure()
        }
    }
}
#endif
