import SwiftUI

// MARK: - Feature flags

/// Surfaces a developer can hide from the native SDK via the console.
public enum SdkFeature: String, Sendable {
    case feedback
    case featureRequests
    case roadmap
    case changelog

    var unavailableTitle: String {
        switch self {
        case .feedback: return "Feedback Unavailable"
        case .featureRequests: return "Requests Unavailable"
        case .roadmap: return "Roadmap Unavailable"
        case .changelog: return "Updates Unavailable"
        }
    }
}

/// Per-surface visibility. Missing keys decode as enabled so older servers stay compatible.
public struct SdkFeatures: Codable, Equatable, Sendable {
    public var feedback: Bool
    public var featureRequests: Bool
    public var roadmap: Bool
    public var changelog: Bool

    public static let allEnabled = SdkFeatures(
        feedback: true,
        featureRequests: true,
        roadmap: true,
        changelog: true
    )

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
public struct ChangelogOverlayConfig: Codable, Equatable, Sendable {
    public var title: String
    public var subtitle: String
    public var entryCount: Int
    public var primaryButton: String
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
public enum SdkTheme: String, Codable, Sendable, CaseIterable, Identifiable {
    case system
    case light
    case dark
    case midnight
    case ocean
    case forest
    case sunset
    case candy

    public var id: String { rawValue }

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
public struct SdkAppearance: Codable, Equatable, Sendable {
    public var theme: SdkTheme
    public var features: SdkFeatures
    public var changelogOverlay: ChangelogOverlayConfig

    public static let defaults = SdkAppearance(
        theme: .system,
        features: .allEnabled,
        changelogOverlay: .defaults
    )

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

extension EnvironmentValues {
    var sdkAppearance: SdkAppearance? {
        get { self[SdkAppearanceKey.self] }
        set { self[SdkAppearanceKey.self] = newValue }
    }
}

/// Wraps host content in the console-selected SDK theme.
public struct CupThreadTheme<Content: View>: View {
    public let client: FeedbackClient
    public let content: Content

    @State private var appearance: SdkAppearance = .defaults

    public init(client: FeedbackClient, @ViewBuilder content: () -> Content) {
        self.client = client
        self.content = content()
    }

    public var body: some View {
        content
            .tint(appearance.theme.accentColor)
            .preferredColorScheme(appearance.theme.preferredColorScheme)
            .environment(\.sdkAppearance, appearance)
            .task {
                appearance = (try? await client.fetchAppConfig())?.sdk ?? .defaults
            }
    }
}

struct SdkSurfaceModifier: ViewModifier {
    let client: FeedbackClient
    let feature: SdkFeature

    @Environment(\.sdkAppearance) private var injected
    @State private var fetched: SdkAppearance?

    private var appearance: SdkAppearance { injected ?? fetched ?? .defaults }

    func body(content: Content) -> some View {
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
        .task {
            if injected == nil {
                fetched = (try? await client.fetchAppConfig())?.sdk ?? .defaults
            }
        }
    }
}

struct FeatureDisabledView: View {
    let feature: SdkFeature

    var body: some View {
        ContentUnavailableView {
            Label(feature.unavailableTitle, systemImage: "eye.slash")
        } description: {
            Text("This surface is turned off in the CupThread console.")
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
