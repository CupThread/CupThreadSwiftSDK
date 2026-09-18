import SwiftUI

// MARK: - Feature flags

/// Surfaces a developer can hide from the native SDK via the console.
public enum SdkFeature: String, Sendable {
    /// The structured feedback form (``FeedbackComposerView``).
    case feedback
    /// The feature request list (``FeatureRequestsView``).
    case featureRequests
    /// The roadmap board (``RoadmapBoardView``).
    case roadmap
    /// The changelog surfaces (``WhatsNewView``, ``ChangelogOverlayView``).
    case changelog

    var unavailableTitle: String {
        switch self {
        case .feedback: return CupThreadStrings.tr("cupthread.features.unavailable_feedback")
        case .featureRequests: return CupThreadStrings.tr("cupthread.features.unavailable_requests")
        case .roadmap: return CupThreadStrings.tr("cupthread.features.unavailable_roadmap")
        case .changelog: return CupThreadStrings.tr("cupthread.features.unavailable_updates")
        }
    }
}

/// Per-surface visibility. Missing keys decode as enabled so older servers stay compatible.
///
/// Mirrors the console's feature switches; SDK views consult it through
/// ``SdkFeature`` and show an "unavailable" placeholder when a surface is off.
public struct SdkFeatures: Codable, Equatable, Sendable {
    /// Whether the feedback form is available.
    public var feedback: Bool
    /// Whether the feature request list is available.
    public var featureRequests: Bool
    /// Whether the roadmap board is available.
    public var roadmap: Bool
    /// Whether the changelog surfaces are available.
    public var changelog: Bool

    /// Every surface enabled — the fallback when the server omits the block.
    public static let allEnabled = SdkFeatures(
        feedback: true,
        featureRequests: true,
        roadmap: true,
        changelog: true
    )

    /// Creates a feature set with every flag explicitly set.
    /// - Parameters:
    ///   - feedback: Whether the feedback form is available.
    ///   - featureRequests: Whether the feature request list is available.
    ///   - roadmap: Whether the roadmap board is available.
    ///   - changelog: Whether the changelog surfaces are available.
    public init(
        feedback: Bool = true,
        featureRequests: Bool = true,
        roadmap: Bool = true,
        changelog: Bool = true
    ) {
        self.feedback = feedback
        self.featureRequests = featureRequests
        self.roadmap = roadmap
        self.changelog = changelog
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        feedback = try container.decodeIfPresent(Bool.self, forKey: .feedback) ?? true
        featureRequests = try container.decodeIfPresent(Bool.self, forKey: .featureRequests) ?? true
        roadmap = try container.decodeIfPresent(Bool.self, forKey: .roadmap) ?? true
        changelog = try container.decodeIfPresent(Bool.self, forKey: .changelog) ?? true
    }

    /// Returns whether the given surface is enabled.
    /// - Parameter feature: The surface to look up.
    /// - Returns: The flag for `feature`.
    public func isEnabled(_ feature: SdkFeature) -> Bool {
        switch feature {
        case .feedback: return feedback
        case .featureRequests: return featureRequests
        case .roadmap: return roadmap
        case .changelog: return changelog
        }
    }
}

// MARK: - Overlay copy

/// Console-configured copy for the latest-changelog overlay.
///
/// All five fields come from the CupThread console, so the overlay copy can
/// change without an app release. Missing keys fall back to
/// ``ChangelogOverlayConfig/defaults``.
public struct ChangelogOverlayConfig: Codable, Equatable, Sendable {
    /// Navigation title of the overlay sheet; defaults to `"What's New"`.
    public var title: String
    /// Optional line shown under the title; empty hides it.
    public var subtitle: String
    /// How many newest entries to show; clamped to 1...10. Defaults to 3.
    public var entryCount: Int
    /// Label of the bottom primary button; defaults to `"Continue"`.
    public var primaryButton: String
    /// Label of the leading close button; defaults to `"Close"`.
    public var closeButton: String

    public static let defaults = ChangelogOverlayConfig(
        title: "What's New",
        subtitle: "",
        entryCount: 3,
        primaryButton: "Continue",
        closeButton: "Close"
    )

    public init(
        title: String = defaults.title,
        subtitle: String = defaults.subtitle,
        entryCount: Int = defaults.entryCount,
        primaryButton: String = defaults.primaryButton,
        closeButton: String = defaults.closeButton
    ) {
        self.title = title
        self.subtitle = subtitle
        self.entryCount = min(10, max(1, entryCount))
        self.primaryButton = primaryButton
        self.closeButton = closeButton
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? Self.defaults.title
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle) ?? Self.defaults.subtitle
        entryCount = min(10, max(1, try container.decodeIfPresent(Int.self, forKey: .entryCount) ?? Self.defaults.entryCount))
        primaryButton = try container.decodeIfPresent(String.self, forKey: .primaryButton) ?? Self.defaults.primaryButton
        closeButton = try container.decodeIfPresent(String.self, forKey: .closeButton) ?? Self.defaults.closeButton
    }
}

// MARK: - Theme presets

/// Named skins selectable in the developer console.
///
/// Each preset pairs a color-scheme preference with an accent color used as
/// the SDK `tint`. `.system` follows the host app's appearance.
public enum SdkTheme: String, Codable, Sendable, CaseIterable, Identifiable {
    case system
    case light
    case dark
    case midnight
    case ocean
    case forest
    case sunset
    case candy

    /// Stable identity for `Identifiable`; equal to `rawValue`.
    public var id: String { rawValue }

    /// Human-readable name, e.g. `"Midnight"`.
    public var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        case .midnight: return "Midnight"
        case .ocean: return "Ocean"
        case .forest: return "Forest"
        case .sunset: return "Sunset"
        case .candy: return "Candy"
        }
    }

    /// Accent applied as the SDK `tint`.
    public var accentColor: Color { Color(hex: spec.accent) }

    /// `nil` follows the host color scheme.
    public var preferredColorScheme: ColorScheme? {
        switch spec.appearance {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }

    fileprivate var spec: ThemeSpec {
        switch self {
        case .system: return ThemeSpec(appearance: .system, accent: "#2563EB")
        case .light: return ThemeSpec(appearance: .light, accent: "#2563EB")
        case .dark: return ThemeSpec(appearance: .dark, accent: "#60A5FA")
        case .midnight: return ThemeSpec(appearance: .dark, accent: "#818CF8")
        case .ocean: return ThemeSpec(appearance: .system, accent: "#0D9488")
        case .forest: return ThemeSpec(appearance: .system, accent: "#16A34A")
        case .sunset: return ThemeSpec(appearance: .system, accent: "#EA580C")
        case .candy: return ThemeSpec(appearance: .system, accent: "#DB2777")
        }
    }
}

private struct ThemeSpec {
    enum Appearance { case system, light, dark }
    let appearance: Appearance
    let accent: String
}

// MARK: - Combined appearance

/// Theme, feature flags, and overlay copy from `GET /api/v1/public/config/{appKey}`.
///
/// Attached to the view hierarchy by ``CupThreadTheme``; views read it from
/// the environment to apply the console configuration. Decoding falls back to
/// ``SdkAppearance/defaults`` for missing blocks so older servers keep working.
public struct SdkAppearance: Codable, Equatable, Sendable {
    /// Console-selected theme preset.
    public var theme: SdkTheme
    /// Per-surface visibility switches.
    public var features: SdkFeatures
    /// Copy and entry count for the latest-changelog overlay.
    public var changelogOverlay: ChangelogOverlayConfig

    /// System theme, all features enabled, default overlay copy.
    public static let defaults = SdkAppearance(
        theme: .system,
        features: .allEnabled,
        changelogOverlay: .defaults
    )

    /// Creates an appearance with explicit values.
    /// - Parameters:
    ///   - theme: Theme preset; defaults to `.system`.
    ///   - features: Feature switches; defaults to all enabled.
    ///   - changelogOverlay: Overlay copy; defaults to `.defaults`.
    public init(
        theme: SdkTheme = .system,
        features: SdkFeatures = .allEnabled,
        changelogOverlay: ChangelogOverlayConfig = .defaults
    ) {
        self.theme = theme
        self.features = features
        self.changelogOverlay = changelogOverlay
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let raw = try container.decodeIfPresent(String.self, forKey: .theme) {
            theme = SdkTheme(rawValue: raw) ?? .system
        } else {
            theme = .system
        }
        features = try container.decodeIfPresent(SdkFeatures.self, forKey: .features) ?? .allEnabled
        changelogOverlay = try container.decodeIfPresent(ChangelogOverlayConfig.self, forKey: .changelogOverlay) ?? .defaults
    }
}

// MARK: - Environment + chrome

private struct SdkAppearanceKey: EnvironmentKey {
    static let defaultValue: SdkAppearance? = nil
}

private struct SdkConfigStatusKey: EnvironmentKey {
    static let defaultValue: SdkConfigStatus? = nil
}

private struct SdkConfigLoaderKey: EnvironmentKey {
    static let defaultValue: SdkConfigLoader? = nil
}

extension EnvironmentValues {
    var sdkAppearance: SdkAppearance? {
        get { self[SdkAppearanceKey.self] }
        set { self[SdkAppearanceKey.self] = newValue }
    }

    var sdkConfigStatus: SdkConfigStatus? {
        get { self[SdkConfigStatusKey.self] }
        set { self[SdkConfigStatusKey.self] = newValue }
    }

    var sdkConfigLoader: SdkConfigLoader? {
        get { self[SdkConfigLoaderKey.self] }
        set { self[SdkConfigLoaderKey.self] = newValue }
    }
}

// MARK: - Surface gating

/// How a feature-gated surface should render for the current config status.
enum SdkSurfaceResolution: Equatable {
    /// The configuration resolved (fetched, or restored from cache) — render
    /// with this appearance.
    case resolved(SdkAppearance)
    /// The first fetch is still in flight; hold the surface back instead of
    /// assuming it is enabled.
    case waiting
    /// The fetch failed and no cached configuration exists — fail closed.
    case unavailable
}

/// Decides how a feature-gated surface renders for the current config status.
/// A status injected by a managing ``CupThreadTheme`` wins over the surface's
/// own loader, so a themed hierarchy never fetches or gates twice.
func sdkSurfaceResolution(injected: SdkConfigStatus?, local: SdkConfigStatus?) -> SdkSurfaceResolution {
    switch injected ?? local ?? .loading {
    case .ready(let appearance): return .resolved(appearance)
    case .failed(let cached?, _): return .resolved(cached)
    case .loading: return .waiting
    case .failed(nil, _): return .unavailable
    }
}

/// Wraps host content in the console-selected SDK theme.
///
/// On first appearance the container fetches the app configuration and applies
/// the console theme (tint + color scheme) to everything inside. Nest your
/// `NavigationStack` in it once, near the root:
///
/// ```swift
/// CupThreadTheme(client: client) {
///     NavigationStack {
///         RoadmapBoardView(client: client, userToken: token)
///     }
/// }
/// ```
///
/// Configuration semantics (see ``SdkConfigStatus``): a successful fetch is
/// persisted per app key, a later failed fetch keeps the last successful
/// configuration in force, and a failure with no cache never enables all
/// features — SDK surfaces stay unavailable until a retry succeeds. Host
/// content still renders with default theming while the configuration is
/// unavailable.
///
/// Individual SDK views already enforce feature flags on their own; this
/// container exists so *host* content surrounding them matches the theme.
public struct CupThreadTheme<Content: View>: View {
    /// The client used to fetch the console configuration.
    public let client: FeedbackClient
    /// The wrapped host content.
    public let content: Content

    private let injectedLoader: SdkConfigLoader?
    @StateObject private var ownedLoader: SdkConfigLoader

    /// Creates the theme container.
    /// - Parameters:
    ///   - client: The shared ``FeedbackClient`` used to fetch the console
    ///     configuration on first appearance.
    ///   - configLoader: An optional host-owned ``SdkConfigLoader``. Pass one
    ///     to observe ``SdkConfigLoader/status`` or trigger manual retries
    ///     with ``SdkConfigLoader/load()``; when `nil` the container creates
    ///     its own loader.
    ///   - content: The content to theme, collected by a result builder.
    public init(
        client: FeedbackClient,
        configLoader: SdkConfigLoader? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.client = client
        self.content = content()
        self.injectedLoader = configLoader
        _ownedLoader = StateObject(wrappedValue: SdkConfigLoader(client: client))
    }

    public var body: some View {
        if let injectedLoader {
            ThemedRoot(loader: injectedLoader, content: content)
        } else {
            ThemedRoot(loader: ownedLoader, content: content)
        }
    }
}

@MainActor
private struct ThemedRoot<Content: View>: View {
    @ObservedObject var loader: SdkConfigLoader
    let content: Content

    private var appearance: SdkAppearance {
        switch loader.status {
        case .ready(let resolved): return resolved
        case .failed(let cached?, _): return cached
        case .loading, .failed(nil, _): return .defaults
        }
    }

    var body: some View {
        content
            .tint(appearance.theme.accentColor)
            .preferredColorScheme(appearance.theme.preferredColorScheme)
            .environment(\.sdkAppearance, appearance)
            .environment(\.sdkConfigStatus, loader.status)
            .environment(\.sdkConfigLoader, loader)
            .safeWebOpenURL()
            .task { await loader.load() }
    }
}

struct SdkSurfaceModifier: ViewModifier {
    let feature: SdkFeature

    @Environment(\.sdkConfigStatus) private var injectedStatus
    @Environment(\.sdkConfigLoader) private var injectedLoader
    @StateObject private var loader: SdkConfigLoader

    init(client: FeedbackClient, feature: SdkFeature) {
        self.feature = feature
        _loader = StateObject(wrappedValue: SdkConfigLoader(client: client))
    }

    func body(content: Content) -> some View {
        gatedBody(content: content)
            .safeWebOpenURL()
            .task {
                guard injectedStatus == nil else { return }
                await loader.load()
            }
    }

    @MainActor
    @ViewBuilder
    private func gatedBody(content: Content) -> some View {
        switch sdkSurfaceResolution(injected: injectedStatus, local: loader.status) {
        case .resolved(let appearance):
            Group {
                if appearance.features.isEnabled(feature) {
                    content
                } else {
                    FeatureDisabledView(feature: feature)
                }
            }
            .tint(appearance.theme.accentColor)
            .preferredColorScheme(appearance.theme.preferredColorScheme)
            .environment(\.sdkAppearance, appearance)
        case .waiting:
            SdkConfigWaitingView()
        case .unavailable:
            LoadErrorView(message: CupThreadStrings.tr("cupthread.config.unavailable_description")) {
                await (injectedLoader ?? loader).load()
            }
        }
    }
}

/// Placeholder shown while the first configuration fetch is in flight.
struct SdkConfigWaitingView: View {
    var body: some View {
        ProgressView()
            .frame(maxWidth: .infinity, minHeight: 120)
            .padding()
    }
}

struct FeatureDisabledView: View {
    let feature: SdkFeature

    var body: some View {
        ContentUnavailableView {
            Label(feature.unavailableTitle, systemImage: "eye.slash")
        } description: {
            Text(CupThreadStrings.tr("cupthread.config.disabled_description"))
        }
        .padding()
    }
}

extension View {
    func sdkSurface(client: FeedbackClient, feature: SdkFeature) -> some View {
        modifier(SdkSurfaceModifier(client: client, feature: feature))
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
