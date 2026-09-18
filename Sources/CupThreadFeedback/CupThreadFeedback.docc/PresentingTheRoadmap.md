# Presenting the Roadmap

Show your public Kanban roadmap grouped by status columns configured in the CupThread console.

![CupThread Roadmap Board](roadmap.jpg)

## Overview

``RoadmapBoardView`` renders your public product roadmap, grouping planned and in-progress feature requests under the columns you define in the CupThread dashboard (such as *Under Review*, *In Progress*, *Planned*, or *Completed*).

## Basic usage

Place ``RoadmapBoardView`` inside a `NavigationStack`:

```swift
import SwiftUI
import CupThreadFeedback

struct RoadmapTab: View {
    let client: FeedbackClient
    let tokenStore = UserTokenStore(appKey: "app_xxx")

    var body: some View {
        NavigationStack {
            RoadmapBoardView(
                client: client,
                userToken: tokenStore.token
            )
        }
    }
}
```

## Adaptive layouts

Roadmap presentation automatically adapts to screen real estate across Apple devices:
- **iPhone / Compact width**: Displays a sticky column selector chip bar with horizontal paging, letting users flick smoothly between columns.
- **iPad / macOS / visionOS**: Renders a multi-column side-by-side Kanban board with horizontal scrolling.
- **tvOS**: Displays structured, focus-friendly sections compatible with Siri Remote navigation.

## Search and status tracking

The roadmap includes an integrated search bar allowing users to quickly search titles and descriptions across all columns simultaneously. Each card displays:
- Title and rich description
- Vote count and status badges
- Milestone version tags
- Shipped indicators

## Complete data, not just the first page

The board pages through every matching request — not only the first server page — so columns stay complete and counts stay accurate as your backlog grows. Search reloads keep this complete-data behavior and preserve on-screen content when a reload fails.

## See also

- ``RoadmapBoardView``
- ``BoardColumn``
- ``FeatureRequestItem``
- <doc:PresentingFeatureRequests>
- <doc:GettingStarted>
