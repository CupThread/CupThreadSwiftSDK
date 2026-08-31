# Presenting Feature Requests

Give your users a voice with real-time search, optimistic voting, milestone filtering, and submission sheets.

![Browse Feature Requests](feature_requests.webp)

## Overview

``FeatureRequestsView`` is a full-featured surface where users can discover what others have suggested, vote on their favorite ideas, and submit new feature requests.

![Submit Feature Request](submit_request.webp)

Key features:
- **Optimistic voting**: Immediate UI response with background server synchronization and duplicate click throttling.
- **Real-time search**: Debounced search querying the CupThread backend.
- **Version filtering**: Filter requests by targeted milestone release versions.
- **Duplicate submission prevention**: Instant search while drafting to highlight existing requests before submission.
- **Anonymous user identity**: Managed by ``UserTokenStore`` so upvotes and submissions persist across app restarts without user login.

## Basic usage

Embed ``FeatureRequestsView`` in a `NavigationStack` with your client and user token:

```swift
import SwiftUI
import CupThreadFeedback

struct FeatureRequestsTab: View {
    let client: FeedbackClient

    var body: some View {
        NavigationStack {
            FeatureRequestsView(
                client: client,
                userToken: UserTokenStore.shared.token
            )
        }
    }
}
```

## Opening directly to compose

If you have a quick action or shortcut in your app (such as "Suggest a Feature" in your settings menu), you can auto-present the compose sheet immediately upon opening:

```swift
FeatureRequestsView(
    client: client,
    userToken: UserTokenStore.shared.token,
    autoPresentCompose: true
)
```

## Pre-filled search

You can pre-filter requests to a specific topic or component:

```swift
FeatureRequestsView(
    client: client,
    userToken: UserTokenStore.shared.token,
    initialSearchText: "Widgets"
)
```

## Platform adaptations

``FeatureRequestsView`` tailors its presentation for each Apple platform:
- **iOS, iPadOS, macOS, visionOS**: Card-based layout with interactive vote badges and markdown-rendered descriptions.
- **tvOS**: A focus-friendly list optimized for Siri Remote navigation.

## See also

- ``FeatureRequestsView``
- ``FeatureRequestItem``
- ``FeatureRequestDraft``
- ``VoteResult``
- <doc:PresentingTheRoadmap>
- <doc:GettingStarted>
