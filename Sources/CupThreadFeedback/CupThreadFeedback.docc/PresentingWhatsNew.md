# Presenting What's New

Display published release notes and changelogs with version badges, shipped feature chips, and email subscription support.

![What's New Changelog](whats_new.jpg)

## Overview

``WhatsNewView`` provides a dedicated changelog feed populated directly from your published release notes on [CupThread.com](https://cupthread.com).

Highlights:
- **Version Badges**: Prominently highlights semantic version tags and localized publication dates.
- **Markdown Release Notes**: Renders formatting, lists, links, and bold text.
- **Linked Features**: Shows chips for user-suggested feature requests that shipped in each release.
- **Email Updates Subscription**: Includes an email subscription button and sheet so users can get notified about future releases.

## Basic usage

Present ``WhatsNewView`` within a `NavigationStack`:

```swift
import SwiftUI
import CupThreadFeedback

struct WhatsNewTab: View {
    let client: FeedbackClient

    var body: some View {
        NavigationStack {
            WhatsNewView(
                client: client,
                userToken: UserTokenStore.shared.token
            )
        }
    }
}
```

## Email updates subscription

The view automatically adds a toolbar icon allowing users to subscribe with their email address. When submitted, the subscription is linked with the user's `userToken`, letting you coordinate updates and marketing communications seamlessly.

## Modal overlay alternative

If you want to present release notes modally right when users open a new app version, check out <doc:PresentingTheChangelogOverlay>.

## See also

- ``WhatsNewView``
- ``ChangelogEntry``
- ``ChangelogLinkedRequest``
- <doc:PresentingTheChangelogOverlay>
- <doc:GettingStarted>
