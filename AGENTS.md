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
- Release SDK: `node scripts/release.mjs --version <semver>`
- Build docs site: `scripts/build-docs.sh docs-site` (DocC source of truth lives in `Sources/CupThreadFeedback/CupThreadFeedback.docc/`)
- Simulator testing: Use the `Demo/` project (`Demo/CupThreadDemo.xcodeproj`). Use the `axe` CLI for simulator automation.

## Documentation Pipeline
- DocC site is published to GitHub Pages (`cupthread.github.io/CupThreadSwiftSDK`) by `.github/workflows/docs.yml` on every push to `main`.
- Documentation MUST be built via `xcodebuild docbuild` + `docc process-archive transform-for-static-hosting` (see `scripts/build-docs.sh`).
- Do NOT add `swift-docc-plugin` (or any doc plugin) to `Package.swift`. Package-level dependencies are resolved by every consumer of this SDK, so a plugin would force all source-package users to fetch it; the xcodebuild route keeps the manifest dependency-free. This is a deliberate, permanent decision — do not "simplify" to the plugin route later.

## Quality Rules
1. Keep the library zero-dependency outside Apple frameworks.
2. Maintain backward compatibility across iOS 17+, macOS 14+, visionOS 1+, and tvOS 17+.
3. Maintain type consistency with CupThread Public API schema.
