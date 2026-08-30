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
- Simulator testing: Use the `Demo/` project (`Demo/CupThreadDemo.xcodeproj`). Use the `axe` CLI for simulator automation.

## Quality Rules
1. Keep the library zero-dependency outside Apple frameworks.
2. Maintain backward compatibility across iOS 17+, macOS 14+, visionOS 1+, and tvOS 17+.
3. Maintain type consistency with CupThread Public API schema.
