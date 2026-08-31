import SwiftUI
import CupThreadFeedback

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

    // Production by default; override for local dev with CUPTHREAD_BASE_URL /
    // CUPTHREAD_APP_KEY (e.g. `SIMCTL_CHILD_CUPTHREAD_BASE_URL=http://127.0.0.1:8787
    // simctl launch ...`).
    private static let baseURL = ProcessInfo.processInfo.environment["CUPTHREAD_BASE_URL"]
        ?? "https://api.cupthread.com"
    private static let appKey = ProcessInfo.processInfo.environment["CUPTHREAD_APP_KEY"]
        ?? "app_demo_placeholder"

    let client = FeedbackClient(
        configuration: FeedbackClientConfiguration(
            baseURL: URL(string: Self.baseURL)!,
            appKey: Self.appKey
        )
    )

    @State private var tab: Tab = Tab.fromLaunchArguments()
    @State private var appearance: SdkAppearance = .defaults
    @State private var showChangelogOverlay = ProcessInfo.processInfo.arguments.contains("-openChangelogOverlay")

    /// Reads an optional `-searchText <text>` launch argument for demos/deep links.
    private static func launchSearchText() -> String {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-searchText"), index + 1 < args.count else { return "" }
        return args[index + 1]
    }

    var body: some View {
        CupThreadTheme(client: client) {
            TabView(selection: $tab) {
                // SDK views are navigation-agnostic: host apps embed them in a
                // NavigationStack so toolbar items (e.g. the compose button) render.
                if appearance.features.roadmap {
                    NavigationStack {
                        RoadmapBoardView(client: client, userToken: UserTokenStore.shared.token)
                    }
                    .tabItem { Label("Roadmap", systemImage: "square.grid.3x3") }
                    .tag(Tab.roadmap)
                }

                if appearance.features.changelog {
                    NavigationStack {
                        WhatsNewView(client: client, userToken: UserTokenStore.shared.token)
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
                            client: client,
                            userToken: UserTokenStore.shared.token,
                            autoPresentCompose: ProcessInfo.processInfo.arguments.contains("-openCompose"),
                            initialSearchText: Self.launchSearchText()
                        )
                    }
                    .tabItem { Label("Requests", systemImage: "list.bullet") }
                    .tag(Tab.requests)
                }

                if appearance.features.feedback {
                    FeedbackDemoView(client: client)
                        .tabItem { Label("Feedback", systemImage: "envelope") }
                        .tag(Tab.feedback)
                }
            }
            .changelogOverlay(client: client, isPresented: $showChangelogOverlay)
        }
        .task {
            if let config = try? await client.fetchAppConfig() {
                appearance = config.sdk
            }
        }
    }
}

/// The SDK composer ships its own success acknowledgment; the demo just hosts it.
struct FeedbackDemoView: View {
    let client: FeedbackClient

    private static var demoInitialDraft: FeedbackDraft? {
        guard ProcessInfo.processInfo.arguments.contains("-prefillFeedback") else { return nil }
        var draft = FeedbackDraft.autofilled()
        draft.title = "Export reports to CSV and PDF"
        draft.description = "It would be super helpful to export weekly feedback analytics "
            + "as CSV or PDF reports so we can share them with stakeholders."
        draft.reporterName = "Alex Developer"
        draft.reporterEmail = "alex@example.com"
        return draft
    }

    var body: some View {
        NavigationStack {
            FeedbackComposerView(
                client: client,
                initialDraft: Self.demoInitialDraft,
                userToken: UserTokenStore.shared.token
            )
        }
    }
}

#Preview {
    ContentView()
}
