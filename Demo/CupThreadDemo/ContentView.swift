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

    init() {
        client = FeedbackClient(
            configuration: FeedbackClientConfiguration(
                baseURL: URL(string: Self.baseURL)!,
                appKey: Self.appKey
            )
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
