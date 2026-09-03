# CupThread Apple SDK

SwiftUI-based SDK for Apple platforms: **iOS 17+, macOS 14+, visionOS 1.0+, tvOS 17+** (additive — one package, platform-adaptive views).

Part of the [CupThread.com](https://cupthread.com) platform.

## 🤖 Recommended: Install via AI Agent (Agentic Coding)

Instead of manually editing `Package.swift` and wiring views by hand, install the official **CupThread Swift AI Skill** into your workspace with [`npx skills`](https://github.com/skills-directory/skills) and let your AI assistant (Claude Code, Cursor, Copilot, Xcode, Windsurf, Codex, Antigravity) integrate and customize it for you:

```sh
npx skills add CupThread/CupThreadAgenticCoding --skill cupthread-swift-sdk
```

Once installed, simply copy and paste this prompt to your AI coding agent:

```text
Integrate the CupThread SwiftUI SDK (roadmap board, changelog overlay, and feedback composer) into this app. Scaffold a dedicated configuration helper with a placeholder for the App Key, and at the end, remind me with step-by-step instructions on how to set my App Key safely (e.g. via xcconfig or local config).
```

---

## CupThread Ecosystem
- 🌐 [CupThread.com](https://cupthread.com) — Feedback SaaS platform, developer console, and API.
- 🍏 [CupThread/CupThreadSwiftSDK](https://github.com/CupThread/CupThreadSwiftSDK) — Apple platform SDK (SwiftUI / SPM / XCFramework).
- 🤖 [CupThread/CupThreadAndroidSDK](https://github.com/CupThread/CupThreadAndroidSDK) — Android SDK (Jetpack Compose / Maven).
- ⚛️ [CupThread/CupThreadReactNativeSDK](https://github.com/CupThread/CupThreadReactNativeSDK) — React Native & Expo SDK (TypeScript).
- 💙 [CupThread/CupThreadFlutterSDK](https://github.com/CupThread/CupThreadFlutterSDK) — Flutter SDK (Dart).
- 🧠 [CupThread/CupThreadAgenticCoding](https://github.com/CupThread/CupThreadAgenticCoding) — AI-friendly CLI & Skills for pair programming.

---

## Visual Showcase

| **Roadmap Board** | **Feature Requests** | **Submit Request** |
| :---: | :---: | :---: |
| <img src="Sources/CupThreadFeedback/CupThreadFeedback.docc/Resources/roadmap.jpg" width="260" alt="Roadmap Board" /> | <img src="Sources/CupThreadFeedback/CupThreadFeedback.docc/Resources/feature_requests.jpg" width="260" alt="Feature Requests" /> | <img src="Sources/CupThreadFeedback/CupThreadFeedback.docc/Resources/submit_request.jpg" width="260" alt="Submit Request Sheet" /> |
| Kanban columns, stage chips & vote counts | Optimistic voting, search & version filter | User request compose sheet |

| **What's New / Changelog** | **Changelog Modal Overlay** | **Feedback Composer** |
| :---: | :---: | :---: |
| <img src="Sources/CupThreadFeedback/CupThreadFeedback.docc/Resources/whats_new.jpg" width="260" alt="What's New Changelog" /> | <img src="Sources/CupThreadFeedback/CupThreadFeedback.docc/Resources/changelog_overlay.jpg" width="260" alt="Changelog Overlay" /> | <img src="Sources/CupThreadFeedback/CupThreadFeedback.docc/Resources/feedback_composer.jpg" width="260" alt="Feedback Composer" /> |
| Markdown release notes & email subscribe | In-app announcement sheet with custom copy | Structured feedback with auto metadata |

---

## Manual Installation

### Swift Package Manager (Recommended)

Add the package dependency in your `Package.swift` by release version or branch:

```swift
dependencies: [
    // By release tag / version:
    .package(url: "https://github.com/CupThread/CupThreadSwiftSDK.git", from: "0.1.0"),
    // Or tracking the latest branch:
    // .package(url: "https://github.com/CupThread/CupThreadSwiftSDK.git", branch: "main"),
]
```

Or add `https://github.com/CupThread/CupThreadSwiftSDK.git` via Xcode (*File > Add Package Dependencies...*).

### Prebuilt Binary Target (XCFramework)

Prebuilt XCFrameworks are published to the CupThread CDN with immutable caching:

```swift
// Package.swift
targets: [
    .binaryTarget(
        name: "CupThreadFeedback",
        url: "https://cdn.cupthread.com/sdks/apple/CupThreadFeedback-0.1.0.xcframework.zip",
        checksum: "ae48499974c5d21d1b33a17831d12f00a52b218654530ae8cfecb796c8d66bcf"
    )
]
```

Or download the zip directly from [Releases](https://github.com/CupThread/CupThreadSwiftSDK/releases) and drag `CupThreadFeedback.xcframework` into your Xcode target's *Frameworks, Libraries, and Embedded Content*.

---

## Quick Start

```swift
import SwiftUI
import CupThreadFeedback

let client = FeedbackClient(
    configuration: FeedbackClientConfiguration(
        baseURL: URL(string: "https://api.cupthread.com")!,
        appKey: "app_xxx"            // from your CupThread Developer Console
    )
)
let userToken = UserTokenStore.shared.token  // stable anonymous UUID
```

`FeedbackPlatform.current` reports the running OS automatically (`ios`, `macos`, `visionos`, `tvos`).

---

## Ready-Made SwiftUI Views

All views adapt per platform (tvOS uses focus-friendly layouts; visionOS and macOS layouts match iOS).

- `RoadmapBoardView(client:userToken:)` — Kanban roadmap grouped by the app's public columns (`GET /api/v1/public/columns`), with vote counts and version badges.
- `FeatureRequestsView(client:userToken:)` — Browse, vote (optimistic), and submit feature requests.
- `CommentsView(client:userToken:featureRequestId:featureRequestTitle:)` — Threaded comments with @author mentions, commenter avatars, and live replies.
- `UserProfileView(client:userId:)` — Public user profile showing public apps and comments history.
- `WhatsNewView(client:userToken:)` — "What's New" changelog list with version badges, friendly dates, chips for shipped feature requests, and email subscription.
- `ChangelogOverlayView` / `.changelogOverlay(client:isPresented:autoMarkSeen:)` — Modal sheet of latest changelog entries with developer console configured copy and built-in seen state persistence.
- `FeedbackComposerView(client:userToken:onSubmit:)` — Structured feedback form with built-in attachment gallery and image picker.

```swift
CupThreadTheme(client: client) {
    NavigationStack {
        RoadmapBoardView(client: client, userToken: userToken)
    }
}

// Present the latest changelog after launch (optionally filtering out already seen versions):
.changelogOverlay(client: client, isPresented: $showWhatsNew)

// Or from UIKit / button action:
try await client.presentLatestChangelog(onlyIfUnseen: true)
```

---

## API Surface

| Method | Endpoint |
| ------ | -------- |
| `submit(_:userToken:)` | `POST /api/v1/feedback` (sends `X-User-Token`) |
| `uploadAttachment(data:filename:mimeType:preferredKind:)` | `POST /api/v1/uploads/{images,r2}` |
| `fetchAppConfig()` | `GET /api/v1/public/config/{appKey}` |
| `prepareChangelogOverlay(onlyIfUnseen:)` | Fetches config + newest changelog entries (with seen state filter) |
| `presentLatestChangelog(onlyIfUnseen:)` | Presents overlay sheet using console copy |
| `hasSeenChangelog(version:)` | Checks `UserDefaults` for previously seen changelog version/ID |
| `markChangelogSeen(version:)` | Marks changelog version/ID as seen |
| `fetchFeatureRequests(userToken:limit:offset:versionId:query:)` | `GET /api/v1/feature-requests` |
| `submitFeatureRequest(_:userToken:)` | `POST /api/v1/feature-requests` |
| `toggleVote(featureRequestId:userToken:)` | `POST /api/v1/feature-requests/{id}/vote` |
| `fetchComments(featureRequestId:)` | `GET /api/v1/feature-requests/{id}/comments` |
| `postComment(featureRequestId:draft:userToken:)` | `POST /api/v1/feature-requests/{id}/comments` |
| `fetchUserProfile(userId:)` | `GET /api/v1/users/{userId}/profile` |
| `fetchColumns()` | `GET /api/v1/public/columns/{appKey}` |
| `fetchVersions()` | `GET /api/v1/public/versions/{appKey}` |
| `fetchChangelog()` | `GET /api/v1/public/apps/{appKey}/changelog` |
| `subscribeToChangelog(email:userToken:)` | `POST /api/v1/public/apps/{appKey}/changelog/subscribe` |
| `unsubscribeFromChangelog(email:)` | `POST /api/v1/public/apps/{appKey}/changelog/unsubscribe` |
| `updateUserAttributes(isPaying:plan:mrr:currency:userToken:)` | `PUT /api/v1/public/apps/{appKey}/user` |

---

## Documentation

The full API documentation (DocC) is published to **[cupthread.github.io/CupThreadSwiftSDK](https://cupthread.github.io/CupThreadSwiftSDK/)**.

Build it locally:

```sh
scripts/build-docs.sh docs-site
python3 -m http.server 8080 --directory docs-site   # preview at http://localhost:8080
```

The site rebuilds and deploys automatically on every push to `main` (see `.github/workflows/docs.yml`).

## Development & Testing

```sh
# Run Swift package unit tests
swift test

# Run UI tests in Demo app & generate core screenshots
xcodebuild test \
    -project Demo/CupThreadDemo.xcodeproj \
    -scheme CupThreadDemo \
    -destination 'platform=iOS Simulator,name=iPhone 17'

# Build DocC documentation site
scripts/build-docs.sh docs-site

# Release a new version (archives 7 slices, creates XCFramework zip, tags & creates release)
node scripts/release.mjs --version 0.1.1
```

## License
MIT
