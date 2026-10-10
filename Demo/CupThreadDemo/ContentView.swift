import SwiftUI
import CupThreadFeedback

/// Process-lifetime owner of everything the demo shares: the `FeedbackClient`,
/// the identity store, and the config loader.
///
/// `FeedbackClient` is documented as "create once and share freely" — it owns
/// the shared search throttle/cooldown and the short-TTL app-config cache.
/// SwiftUI re-creates View values on every parent re-evaluation, so creating
/// the client (or the token store) as a View stored property silently resets
/// both invariants; this model is created exactly once by `CupThreadDemoApp`
/// and passed down as a reference.
///
/// The loader is host-owned (instead of `CupThreadTheme`'s default) so the
/// demo can gate its tab bar on the same resolved configuration the SDK
/// surfaces use, without issuing a second config GET.
@MainActor
final class DemoAppModel: ObservableObject {
    // Production by default; override for local dev with CUPTHREAD_BASE_URL /
    // CUPTHREAD_APP_KEY (e.g. `SIMCTL_CHILD_CUPTHREAD_BASE_URL=http://127.0.0.1:8787
    // simctl launch ...`).
    private static let baseURL = ProcessInfo.processInfo.environment["CUPTHREAD_BASE_URL"]
        ?? "https://api.cupthread.com"
    private static let appKey = ProcessInfo.processInfo.environment["CUPTHREAD_APP_KEY"]
        ?? "app_demo_placeholder"

    let client: FeedbackClient
    /// Identity scoped to this demo's app key — hosts embedding several
    /// CupThread apps create one store per app key.
    let tokenStore: UserTokenStore
    let config: SdkConfigLoader

    /// Whether the demo talks to the mock fixtures instead of a real
    /// backend. Mocks are on unless a developer explicitly points the demo
    /// at a server with `CUPTHREAD_BASE_URL` (and only `CUPTHREAD_USE_MOCKS=1`
    /// forces them back on over an explicit backend).
    private static let usesMockTransport: Bool = {
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains("-uiTesting")
            || processInfo.arguments.contains("-mockData")
            || processInfo.environment["CUPTHREAD_USE_MOCKS"] == "1"
            || processInfo.environment["CUPTHREAD_BASE_URL"] == nil
    }()

    /// Session with the mock `URLProtocol` installed directly in
    /// `protocolClasses`. The global `URLProtocol.registerClass` registry is
    /// not consulted for `URLSessionConfiguration.default` sessions on
    /// current OSes, so a registerClass-based mock silently misses requests
    /// and the app talks to production instead of the fixtures; an explicit
    /// session makes interception deterministic on every OS.
    private static let mockSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DemoMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }()

    /// Debug-grade Turnstile provider token from the `-mockTurnstileToken`
    /// launch argument (issue #53 harness): `-mockTurnstileToken <value>`
    /// presents `<value>`, the bare flag presents a deterministic synthetic
    /// token. When present, the client is created with a
    /// `turnstileTokenProvider`, so intake submissions carry a token from the
    /// first attempt and the 403 → provider → single-retry path can be
    /// exercised against the emulated gate (`-emulateTurnstileGate`) or a
    /// real gated backend without rendering the actual widget.
    private static let mockTurnstileToken: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-mockTurnstileToken") else { return nil }
        guard index + 1 < args.count, !args[index + 1].hasPrefix("-") else {
            return "mock_cf_token_auto"
        }
        return args[index + 1]
    }()

    init() {
        // When mocks are on, the injected session bypasses the SDK's default
        // session (whose same-origin redirect limiter protects real-backend
        // use); mock fixtures never redirect, so nothing is lost in mock mode.
        client = FeedbackClient(
            configuration: FeedbackClientConfiguration(
                baseURL: URL(string: Self.baseURL)!,
                appKey: Self.appKey
            ),
            session: Self.usesMockTransport ? Self.mockSession : FeedbackClient.defaultSession,
            turnstileTokenProvider: Self.mockTurnstileToken.map { token in
                { (_: TurnstileChallenge) -> String? in token }
            }
        )
        tokenStore = UserTokenStore(appKey: Self.appKey)
        config = SdkConfigLoader(client: client)
    }
}

struct ContentView: View {
    enum Tab: Int {
        case roadmap, whatsNew, requests, feedback

        /// Reads an optional `-initialTab <roadmap|whatsNew|requests|feedback>` launch argument
        /// so demos/screenshots can jump straight to a specific view.
        static func fromLaunchArguments() -> Tab {
            let args = ProcessInfo.processInfo.arguments
            guard let index = args.firstIndex(of: "-initialTab"),
                  index + 1 < args.count else { return .roadmap }
            switch args[index + 1] {
            case "whatsNew": return .whatsNew
            case "requests": return .requests
            case "feedback": return .feedback
            default: return .roadmap
            }
        }
    }

    let model: DemoAppModel
    /// Observing the loader (not just the model) is what re-renders the tab
    /// bar when the console configuration resolves.
    @ObservedObject private var config: SdkConfigLoader

    @State private var tab: Tab = Tab.fromLaunchArguments()
    @State private var showChangelogOverlay = ProcessInfo.processInfo.arguments.contains("-openChangelogOverlay")

    init(model: DemoAppModel) {
        self.model = model
        _config = ObservedObject(wrappedValue: model.config)
    }

    /// Reads an optional `-searchText <text>` launch argument for demos/deep links.
    private static func launchSearchText() -> String {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-searchText"), index + 1 < args.count else { return "" }
        return args[index + 1]
    }

    /// Same resolution rules as the SDK's `ThemedRoot`: the resolved
    /// appearance wins, a failure keeps the last-good cached appearance, and
    /// anything else falls back to defaults (all tabs visible).
    private var appearance: SdkAppearance {
        switch config.status {
        case .ready(let resolved): return resolved
        case .failed(let cached?, _): return cached
        case .loading, .failed(nil, _): return .defaults
        }
    }

    var body: some View {
        CupThreadTheme(client: model.client, configLoader: model.config) {
            TabView(selection: $tab) {
                // SDK views are navigation-agnostic: host apps embed them in a
                // NavigationStack so toolbar items (e.g. the compose button) render.
                if appearance.features.roadmap {
                    NavigationStack {
                        RoadmapBoardView(client: model.client, userToken: model.tokenStore.token)
                    }
                    .tabItem { Label("Roadmap", systemImage: "square.grid.3x3") }
                    .tag(Tab.roadmap)
                }

                if appearance.features.changelog {
                    NavigationStack {
                        WhatsNewView(client: model.client, userToken: model.tokenStore.token)
                            .toolbar {
                                ToolbarItem(placement: .primaryAction) {
                                    Button("Latest") { showChangelogOverlay = true }
                                }
                            }
                    }
                    .tabItem { Label("What's New", systemImage: "sparkles") }
                    .tag(Tab.whatsNew)
                }

                if appearance.features.featureRequests {
                    NavigationStack {
                        FeatureRequestsView(
                            client: model.client,
                            userToken: model.tokenStore.token,
                            autoPresentCompose: ProcessInfo.processInfo.arguments.contains("-openCompose"),
                            initialSearchText: Self.launchSearchText()
                        )
                    }
                    .tabItem { Label("Requests", systemImage: "list.bullet") }
                    .tag(Tab.requests)
                }

                if appearance.features.feedback {
                    FeedbackDemoView(client: model.client, userToken: model.tokenStore.token)
                        .tabItem { Label("Feedback", systemImage: "envelope") }
                        .tag(Tab.feedback)
                }
            }
            .changelogOverlay(client: model.client, isPresented: $showChangelogOverlay)
        }
    }
}

/// The SDK composer ships its own success acknowledgment; the demo just hosts it.
struct FeedbackDemoView: View {
    let client: FeedbackClient
    let userToken: String

    private static var demoInitialDraft: FeedbackDraft? {
        guard ProcessInfo.processInfo.arguments.contains("-prefillFeedback") else { return nil }
        var draft = FeedbackDraft.autofilled()
        draft.title = "Export reports to CSV and PDF"
        draft.description = "It would be super helpful to export weekly feedback analytics "
            + "as CSV or PDF reports so we can share them with stakeholders."
        draft.reporterName = "Alex Developer"
        draft.reporterEmail = "alex@example.com"
        draft.attachments = [
            FeedbackAttachment(
                kind: .image,
                key: "uploads/analytics_preview.png",
                url: URL(string: "https://example.com/uploads/analytics_preview.png")!,
                filename: "analytics_preview.png",
                mimeType: "image/png",
                size: 245_760
            )
        ]
        return draft
    }

    var body: some View {
        NavigationStack {
            FeedbackComposerView(
                client: client,
                initialDraft: Self.demoInitialDraft,
                userToken: userToken
            )
        }
    }
}

#Preview {
    ContentView(model: DemoAppModel())
}
