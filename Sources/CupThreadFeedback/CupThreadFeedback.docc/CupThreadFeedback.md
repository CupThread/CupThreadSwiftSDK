# CupThread Feedback SDK

Native SwiftUI surfaces for feedback, feature requests, roadmaps, and changelogs — powered by [CupThread.com](https://cupthread.com).

Add one client, drop in a view, and your Apple apps (iOS 17+, macOS 14+, visionOS 1+, tvOS 17+) get a production-ready feedback loop: structured feedback with attachments, votable feature requests, a kanban roadmap, and a "What's New" changelog — all themed and feature-gated from the CupThread developer console without shipping a new app version.

## Essentials

- <doc:GettingStarted>
- <doc:CustomizingAppearance>

## Presenting surfaces

- <doc:PresentingFeedbackComposer>
- <doc:PresentingFeatureRequests>
- <doc:PresentingTheRoadmap>
- <doc:PresentingWhatsNew>
- <doc:PresentingTheChangelogOverlay>

## Core types

- ``FeedbackClient``: The HTTP client that talks to the CupThread API.
- ``FeedbackClientConfiguration``: Base URL, app key, and reported platform.
- ``UserTokenStore``: Stable anonymous token that links votes and requests to a device.

## Feedback

- ``FeedbackDraft``: A feedback draft before submission.
- ``FeedbackAttachment``: An uploaded file attached to a draft.
- ``FeedbackSubmissionResult``: The server's response to a submission.
- ``FeedbackComposerView``: Ready-made feedback form.

## Feature requests & roadmap

- ``FeatureRequestItem``: A public feature request.
- ``FeatureRequestDraft``: A new feature request before submission.
- ``ListFeatureRequestsResult``: Paginated list response.
- ``FeatureRequestSubmissionResult``: Response to a new request.
- ``VoteResult``: Response to a vote toggle.
- ``FeatureRequestsView``: Browse, search, and vote on requests.
- ``RoadmapBoardView``: Kanban board grouped by public columns.

## Changelog & "What's New"

- ``ChangelogEntry``: A published changelog entry.
- ``ChangelogLinkedRequest``: A feature request that shipped with an entry.
- ``WhatsNewView``: The "What's New" changelog surface.
- ``ChangelogOverlayView``: Modal latest-changelog sheet.
- `changelogOverlay(client:isPresented:)`: SwiftUI modifier for the overlay.
- ``FeedbackClient/presentLatestChangelog()``: Programmatic overlay presentation.
- ``FeedbackClient/prepareChangelogOverlay()``: Fetch overlay data without presenting.
- ``FeedbackClient/fetchChangelog()``, ``FeedbackClient/subscribeToChangelog(email:userToken:)``, ``FeedbackClient/unsubscribeFromChangelog(email:)``

## Appearance & feature flags

- ``SdkAppearance``: Theme, feature flags, and overlay copy from the console.
- ``SdkTheme``: Named theme presets.
- ``SdkFeatures``: Per-surface visibility switches.
- ``SdkFeature``: The surface a flag controls.
- ``ChangelogOverlayConfig``: Console-configured overlay copy.
- ``CupThreadTheme``: Container view that applies the console theme.

## Support

- ``FeedbackPlatform``: Platforms the backend distinguishes.
- ``PublicAppConfig``: The app's public configuration.
- ``BoardColumn``: A roadmap board column.
- ``AppVersion``: A released or planned app version.
- ``FeedbackClientError``: Errors thrown by ``FeedbackClient``.
