# Presenting the Changelog Overlay

Show your app's latest updates right after launch — with copy you edit in the CupThread console, not in code.

![Changelog Overlay Modal](changelog_overlay.png)

## SwiftUI

The simplest integration is the ``changelogOverlay(client:isPresented:)`` modifier. Present it from your root scene after launch:

```swift
struct MyApp: App {
    @State private var showWhatsNew = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task { showWhatsNew = true }
                .changelogOverlay(client: client, isPresented: $showWhatsNew)
        }
    }
}
```

The overlay fetches the app configuration and newest entries, then renders the title, subtitle, button labels, and entry count you configured in the CupThread console.

## UIKit / AppKit or custom presentation

Call ``FeedbackClient/presentLatestChangelog()`` from any button action or lifecycle hook:

```swift
try await client.presentLatestChangelog()
```

The method returns `false` (without throwing) when there is nothing to show — for example when the console hid the changelog, no entries are published, or no window is available to present from. Network failures throw so you can log them.

For full control over when the sheet appears, split the two halves yourself: ``FeedbackClient/prepareChangelogOverlay()`` fetches the data and returns `nil` when the overlay should stay hidden, and ``ChangelogOverlayView`` renders it wherever you like.
