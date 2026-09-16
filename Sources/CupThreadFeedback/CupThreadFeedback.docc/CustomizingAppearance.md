# Customizing Appearance and Theming

Style feedback views dynamically and control feature visibility from the CupThread developer console without shipping new app builds.

## Overview

The CupThread SDK allows you to configure your app's visual theme and surface visibility remotely from the [CupThread.com](https://cupthread.com) developer console.

## Applying the CupThread theme

Wrap your view hierarchy or navigation root in ``CupThreadTheme``:

```swift
import SwiftUI
import CupThreadFeedback

@main
struct MyApp: App {
    let client = FeedbackClient(
        configuration: FeedbackClientConfiguration(
            baseURL: URL(string: "https://api.cupthread.com")!,
            appKey: "app_your_key_here"
        )
    )

    var body: some Scene {
        WindowGroup {
            CupThreadTheme(client: client) {
                ContentView(client: client)
            }
        }
    }
}
```

``CupThreadTheme`` automatically fetches your remote ``SdkAppearance`` and injects the selected theme colors, corner radii, and surface options into the SwiftUI environment.

The fetched configuration is resilient by design:

- Every successful fetch is persisted per app key.
- If a later fetch fails, the last successful configuration stays in force — theme, feature flags, and overlay copy never roll back to defaults mid-outage.
- If the very first fetch fails (nothing cached yet), SDK surfaces stay unavailable with a retry action instead of silently enabling everything. Your host content still renders with default theming.

Pass a host-owned ``SdkConfigLoader`` to ``CupThreadTheme`` to observe the load state or trigger manual retries from your own UI.

## Theme presets

The SDK supports multiple visual presets configured in the developer console:
- **System**: Adapts cleanly to the device's light and dark mode colors.
- **Midnight**: Deep dark backgrounds with high-contrast accents.
- **Sunset**: Warm tones suitable for creative and lifestyle apps.
- **Emerald**: Modern green accents.
- **Lavender**: Subtle violet accents.

## Dynamic feature gating

You can enable or disable individual SDK surfaces in the console:
- **Feedback Composer** (`.feedback`)
- **Feature Requests** (`.featureRequests`)
- **Roadmap** (`.roadmap`)
- **Changelog** (`.changelog`)

When a feature is disabled in the developer console, the corresponding view automatically displays an informative placeholder banner informing the user that the section is currently unavailable, preventing crashes or blank states. While the configuration cannot be loaded at all (see above), surfaces stay unavailable rather than defaulting to enabled, so a console kill-switch is never bypassed by a network failure.

## Programmatic configuration access

To inspect or react to the console configuration in your own custom views, fetch ``PublicAppConfig``:

```swift
let config = try await client.fetchAppConfig()
print("App name: \(config.name)")
print("Active theme: \(config.appearance.theme)")
print("Roadmap enabled: \(config.appearance.features.roadmap)")
```

## See also

- ``CupThreadTheme``
- ``SdkConfigLoader``
- ``SdkConfigStatus``
- ``SdkAppearance``
- ``SdkTheme``
- ``SdkFeatures``
- ``PublicAppConfig``
- <doc:GettingStarted>
