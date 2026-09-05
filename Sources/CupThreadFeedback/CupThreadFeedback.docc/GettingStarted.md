# Getting Started

Learn how to collect feedback, feature requests, and changelog views in your Apple app with the CupThread SDK.

## Requirements

- iOS 17+, macOS 14+, visionOS 1+, or tvOS 17+
- An [app key](https://cupthread.com) from the CupThread developer console (starts with `app_`)

## Add the package

In Xcode choose **File > Add Package Dependencies…** and enter:

```
https://github.com/CupThread/CupThreadSwiftSDK.git
```

Or add it to your `Package.swift` dependencies:

```swift
.package(url: "https://github.com/CupThread/CupThreadSwiftSDK.git", from: "0.1.0")
```

## Create a client

``FeedbackClient`` is a sendable value you create once and share. It only needs your API base URL and app key:

```swift
import CupThreadFeedback

let client = FeedbackClient(
    configuration: FeedbackClientConfiguration(
        baseURL: URL(string: "https://api.cupthread.com")!,
        appKey: "app_xxx"
    )
)
```

Every end-user interaction is tied to an anonymous token so votes and pending requests survive relaunches without requiring sign-in. ``UserTokenStore`` persists one for you:

```swift
let userToken = UserTokenStore.shared.token
```

## Show a surface

All surfaces are SwiftUI views. Embed them in a `NavigationStack` and wrap your hierarchy in ``CupThreadTheme`` so the console-selected theme and feature flags apply everywhere:

```swift
struct FeedbackTab: View {
    var body: some View {
        CupThreadTheme(client: client) {
            NavigationStack {
                FeatureRequestsView(client: client, userToken: UserTokenStore.shared.token)
            }
        }
    }
}
```

Available surfaces:

| View | Purpose | Guide |
| ---- | ------- | ----- |
| ``RoadmapBoardView`` | Kanban roadmap grouped by the app's public columns | <doc:PresentingTheRoadmap> |
| ``FeatureRequestsView`` | Browse, search, vote, and submit feature requests | <doc:PresentingFeatureRequests> |
| ``WhatsNewView`` | "What's New" changelog with email subscription | <doc:PresentingWhatsNew> |
| ``FeedbackComposerView`` | Structured feedback form with attachment uploads | <doc:PresentingFeedbackComposer> |
| ``ChangelogOverlayView`` | Modal "What's New" sheet presented after app launch | <doc:PresentingTheChangelogOverlay> |

Each view adapts to its platform: iPhone gets a compact paged layout, iPad/macOS/visionOS get the wide board, and tvOS gets focus-friendly lists.

### Visual Preview

![CupThread Roadmap Surface](roadmap.jpg)

![CupThread Feature Requests Surface](feature_requests.jpg)

![CupThread What's New Surface](whats_new.jpg)

![CupThread Feedback Composer](feedback_composer.jpg)

## Gate surfaces from the console

The CupThread console controls which surfaces are visible, the theme, and the changelog overlay copy. The SDK applies this automatically through the `.sdkSurface(client:feature:)` modifier wrappers — when you disable a surface (for example *Roadmap*) in the console, the view shows an "unavailable" placeholder instead of crashing or disappearing. See <doc:CustomizingAppearance> for details.

## Submit feedback programmatically

If you build your own UI, skip the views and use ``FeedbackClient`` directly:

```swift
var draft = FeedbackDraft.autofilled()
draft.title = "Export to CSV"
draft.description = "I would love to export my reports."

let result = try await client.submit(draft, userToken: UserTokenStore.shared.token)
print(result.submissionId)
```

Drafts can carry attachments you upload with ``FeedbackClient/uploadAttachment(data:filename:mimeType:preferredKind:userToken:)`` and arbitrary metadata for your own triage tooling.

## Explore guides & articles

- <doc:PresentingFeedbackComposer>
- <doc:PresentingFeatureRequests>
- <doc:PresentingTheRoadmap>
- <doc:PresentingWhatsNew>
- <doc:PresentingTheChangelogOverlay>
- <doc:CustomizingAppearance>
