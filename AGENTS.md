# AGENTS.md — CupThread Apple SDK

## Repository Purpose
`CupThreadSwiftSDK` is the official Apple SDK for [CupThread.com](https://cupthread.com) (iOS 17+, macOS 14+, visionOS 1.0+, tvOS 17+).

## Multi-Repo Ecosystem
- **CupThread Platform**: [`CupThread.com`](https://cupthread.com) (Main SaaS website & backend API)
- **Apple SDK**: [`CupThread/CupThreadSwiftSDK`](https://github.com/CupThread/CupThreadSwiftSDK) (SwiftUI / SPM / XCFramework)
- **Android SDK**: [`CupThread/CupThreadAndroidSDK`](https://github.com/CupThread/CupThreadAndroidSDK) (Kotlin + Jetpack Compose)
- **Agentic Coding & CLI**: [`CupThread/CupThreadAgenticCoding`](https://github.com/CupThread/CupThreadAgenticCoding) (AI Skills, CLI tools)

## Architecture & API Contract
- Public endpoints live under `/api/v1/public/*` and `/api/v1/*` on `https://api.cupthread.com`:
  - `GET /api/v1/public/config/:appKey` — App configuration, theme, allowed platforms, changelog copy.
  - `GET /api/v1/public/columns/:appKey` — Kanban board columns for roadmap.
  - `GET /api/v1/public/versions/:appKey` — App release versions.
  - `GET /api/v1/public/apps/:appKey/changelog` — Published release notes & changelog entries.
  - `POST /api/v1/public/apps/:appKey/changelog/subscribe` — Email subscription.
  - `POST /api/v1/public/apps/:appKey/changelog/unsubscribe` — Unsubscribe from updates.
  - `PUT /api/v1/public/apps/:appKey/user` — Report user attributes (paying status, MRR).
  - `GET /api/v1/feature-requests` — Feature requests list and search with `q` query parameter.
  - `POST /api/v1/feature-requests` — Submit new feature request.
  - `POST /api/v1/feature-requests/:id/vote` — Toggle vote on a feature request.
  - `POST /api/v1/feedback` — Submit feedback draft with attachments.
  - `POST /api/v1/uploads/images` & `POST /api/v1/uploads/r2` — Media and log attachment uploads.

## Development & Testing
- Run test suite: `swift test`
- Run linter: `swiftlint lint --strict` (config in `.swiftlint.yml`; installed via `brew install swiftlint`, never as an SPM plugin — same zero-dependency rule as the doc pipeline)
- Release SDK: `node scripts/release.mjs --version <semver>`
- Release dry-run verification: `node scripts/release.mjs --version <semver> --dry-run`
- Build docs site: `scripts/build-docs.sh docs-site` (DocC source of truth lives in `Sources/CupThreadFeedback/CupThreadFeedback.docc/`)
- Simulator testing: Use the `Demo/` project (`Demo/CupThreadDemo.xcodeproj`). Use the `axe` CLI for simulator automation.

### Supported Platform Matrix & Release Triage
The SDK targets four Apple operating systems across seven release archive slices:
| Platform Slice | Generic Xcodebuild Destination | Target OS Version | Architectures |
|---|---|---|---|
| `ios` | `generic/platform=iOS` | iOS 17.0+ | arm64 |
| `ios-simulator` | `generic/platform=iOS Simulator` | iOS 17.0+ | arm64, x86_64 |
| `macos` | `generic/platform=macOS` | macOS 14.0+ | arm64, x86_64 |
| `visionos` | `generic/platform=visionOS` | visionOS 1.0+ | arm64 |
| `visionos-simulator` | `generic/platform=visionOS Simulator` | visionOS 1.0+ | arm64, x86_64 |
| `tvos` | `generic/platform=tvOS` | tvOS 17.0+ | arm64 |
| `tvos-simulator` | `generic/platform=tvOS Simulator` | tvOS 17.0+ | arm64, x86_64 |

#### Failure Triage
- **Platform compilation errors**: If an archive slice fails with an unavailable API error (e.g. `RoundedBorderTextFieldStyle` is unavailable on tvOS; certain sheet or navigation styles differ between macOS and tvOS):
  1. Inspect the error output to identify the missing or unavailable symbol.
  2. Use `#if os(...)` conditional compilation to branch platform-specific presentation (e.g., `#if os(tvOS)` vs `#if os(iOS) || os(visionOS)`).
  3. Validate the single slice locally with:
     ```sh
     xcodebuild archive \
       -scheme CupThreadFeedback \
       -destination 'generic/platform=<Platform>' \
       -archivePath /tmp/<Platform>.xcarchive \
       SKIP_INSTALL=NO \
       BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
       -quiet
     ```
- **XCFramework assembly errors**: `scripts/release.mjs` verifies that all seven `.framework` slices exist before invoking `xcodebuild -create-xcframework`. If a slice is missing, check the preceding archive step logs for compiler or toolchain warnings and errors.
- **CI platform matrix**: CI compiles all seven slices in the `build-platforms` matrix job and runs `release-dry-run` to ensure regressions on any platform fail before merging into `main`.


## Documentation Pipeline
- DocC site is published to GitHub Pages (`cupthread.github.io/CupThreadSwiftSDK`) by `.github/workflows/docs.yml` on every push to `main`.
- Documentation MUST be built via `xcodebuild docbuild` + `docc process-archive transform-for-static-hosting` (see `scripts/build-docs.sh`).
- Do NOT add `swift-docc-plugin` (or any doc plugin) to `Package.swift`. Package-level dependencies are resolved by every consumer of this SDK, so a plugin would force all source-package users to fetch it; the xcodebuild route keeps the manifest dependency-free. This is a deliberate, permanent decision — do not "simplify" to the plugin route later.

## Quality Rules
1. Keep the library zero-dependency outside Apple frameworks.
2. Maintain backward compatibility across iOS 17+, macOS 14+, visionOS 1+, and tvOS 17+.
3. Maintain type consistency with CupThread Public API schema.
