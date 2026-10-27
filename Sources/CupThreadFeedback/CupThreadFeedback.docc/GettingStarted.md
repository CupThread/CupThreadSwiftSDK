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

Every end-user interaction is tied to an anonymous token so votes and pending requests survive relaunches without requiring sign-in. ``UserTokenStore`` persists one for you, scoped to your app key (hosts embedding several CupThread apps create one store per app key so identities never bleed across them):

```swift
let tokenStore = UserTokenStore(appKey: "app_xxx")
let userToken = tokenStore.token
```

### Human verification (Turnstile)

Read-only use — the roadmap board, browsing and voting on feature requests, and the changelog — works with the bare client above. Writing is different: production intake (feedback submission, attachment upload sessions, and feature-request submission) is gated behind Cloudflare Turnstile, so every intake call fails with ``FeedbackClientError/turnstileRequired(message:requestId:)`` until the client is created with a `turnstileTokenProvider` that mints tokens under the widget binding the SDK asks for:

```swift
let client = FeedbackClient(
    configuration: configuration,
    turnstileTokenProvider: { challenge in
        // `challenge.action` names the gated surface (feedback or
        // feature-request) and `challenge.cdata` is the app key —
        // render (or server-mint) the token under exactly this pair.
        await MyVerificationCoordinator.currentToken(for: challenge)
    }
)
```

The provider contract — the `(action, cdata)` binding per endpoint and the automatic single retry after a gate rejection — is described in <doc:PresentingFeedbackComposer>.

Hosts that would rather let the SDK run the challenge can skip the provider. When the app configuration publishes a Turnstile site key (``PublicAppConfig/turnstile``), ``FeedbackComposerView`` and the feature-request compose sheet present ``TurnstileChallengeSheet`` after a gated submission is rejected: it loads the portal's hosted challenge page in a `WKWebView`, captures the minted token from the page's bridge, and resubmits with it. The draft stays intact across a cancelled or failed challenge. The sheet is available on iOS, macOS, and visionOS; tvOS has no WebKit, so token-gated intake there needs a provider.

### Reporting paying users securely

Reports of `isPaying`, `plan`, `mrr`, and `currency` feed revenue-weighted triage, so `PUT /api/v1/public/apps/{appKey}/user` only accepts them **verified** — HMAC-SHA256 signed with your app's SDK signing secret. Keep that secret on your own server (where the entitlement truth already lives: StoreKit server notifications, RevenueCat webhooks, …) and hand signing to a `userAttributesSigner` provider, so the secret never ships inside the app binary:

```swift
let client = FeedbackClient(
    configuration: configuration,
    userAttributesSigner: { request in
        // request.canonicalString is the exact UTF-8 bytes to HMAC-SHA256
        // with the SDK signing secret held on your server.
        let signed = try await myBackend.signUserAttributes(request.canonicalString)
        // signed.timestamp must be the canonical string's last line (the
        // epoch seconds it was signed over) — the SDK verifies the
        // equality locally and fails fast with `.invalidSignature`
        // otherwise (#579).
        return UserAttributesSignature(signature: signed.signature, timestamp: signed.timestamp)
    }
)

try await client.updateUserAttributes(
    isPaying: true,
    plan: "pro",
    mrr: 12.5,
    currency: "USD",
    userToken: tokenStore.token
)
```

The provider receives the canonical string the SDK built (its last line is the server-clock-corrected timestamp) and returns the 64-hex-character signature plus that timestamp; the SDK validates the signature grammar and the timestamp equality locally (a returned timestamp different from the one embedded in the signed canonical string cannot verify server-side, so it is rejected before any request is spent) and sends both verbatim. A `stale_signature` rejection re-consults the provider exactly once with a fresh corrected timestamp; `invalid_signature` is never retried. When the provider returns `nil`, the SDK falls back to the embedded ``FeedbackClientConfiguration/signingSecret`` — and with neither available the report is sent unsigned and rejected by the server.

The attribute values are validated against the live schema's bounds before any signing material is consulted (issue #607): `plan` must be 1–64 Unicode code points (there is no empty-string "no plan" — omit the attribute to leave it unchanged, or pass `.null` on the ``UserAttributesSigner/Field`` overload to clear it), `mrr` must be between `0` and `1_000_000` inclusive, and `currency` must be exactly three ASCII letters, sent as given. The limits are published on ``UserAttributeLimits`` so hosts can gate their own forms, and an out-of-bounds value throws ``FeedbackClientError/invalidAttributeValue(attribute:message:requestId:)`` before the signer provider is called or any request is sent — a report the server could only reject would otherwise also silently drop every sibling write in the same `PUT`.

> Warning: Configuring the embedded `signingSecret` compiles the signing key into your app binary. It is **not tamper-resistant**: anyone who installs the app can extract it and forge verified payment attributes for arbitrary end users. Reserve it for internal, debug, or otherwise trusted builds, and prefer backend-delegated signing in production.

### Network security: redirects never leave the API origin

The default session refuses any HTTP redirect that leaves the configured `baseURL`'s origin (scheme, host, and effective port). URLSession would otherwise re-send every request header — including `Authorization: Bearer …` and the `X-User-Token` identity — and, on 307/308 redirects, the request body (e.g. attachment upload bytes) to whatever host the `Location` header names. A refused redirect surfaces the 3xx response itself as ``FeedbackClientError/unexpectedStatus(code:message:requestId:)`` instead of silently succeeding against the redirect target. Same-origin redirects are followed normally. The policy ships on the SDK's default session, and every SDK request additionally enforces it per-task — so an injected `session:` is covered too, with no redirect configuration required (issue #571).

## Show a surface

All surfaces are SwiftUI views. Embed them in a `NavigationStack` and wrap your hierarchy in ``CupThreadTheme`` so the console-selected theme and feature flags apply everywhere:

```swift
struct FeedbackTab: View {
    var body: some View {
        CupThreadTheme(client: client) {
            NavigationStack {
                FeatureRequestsView(client: client, userToken: tokenStore.token)
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

let result = try await client.submit(draft, userToken: tokenStore.token)  // from the store created above
print(result.submissionId)
```

Drafts can carry attachments you upload with ``FeedbackClient/uploadAttachment(data:filename:mimeType:userToken:turnstileToken:)`` (or ``FeedbackClient/uploadAttachment(fileURL:filename:mimeType:userToken:turnstileToken:)`` for large files, which streams from disk instead of buffering the body in memory) and arbitrary metadata for your own triage tooling. Metadata is sanitized locally per the server's redaction contract (credential-looking keys are redacted, values truncated, oversized payloads shrunk). The reserved keys `sdk`, `sdkVersion`, `platform`, and `submittedAt` are authored by the SDK itself: draft entries with those names are replaced before sending, and all other custom keys are preserved.

One submission may reference at most ``FeedbackSubmissionLimits/maxAttachmentCount`` (8) attachment uploads — the live `FeedbackSubmissionInput` schema's `uploadIds` cap (issue #613). Each one-shot upload helper creates its own session, so nothing upstream sees the aggregate: a host that builds its own attachment UI can legitimately collect nine receipts and hand them to one `submit`. The SDK refuses such a draft locally with ``FeedbackClientError/tooManyAttachments(message:requestId:)`` before the Turnstile provider is consulted or any request is sent, so the already-uploaded files are not stranded behind a `400` that retrying cannot clear; remove attachments and submit again with the remaining receipts. ``FeedbackAttachmentStateMachine/canSubmit(draft:)`` applies the same verdict, and ``FeedbackSubmissionLimits/referencedUploadCount(in:)`` exposes the counted figure so custom pickers can stop at the bound.

## Explore guides & articles

- <doc:PresentingFeedbackComposer>
- <doc:PresentingFeatureRequests>
- <doc:PresentingTheRoadmap>
- <doc:PresentingWhatsNew>
- <doc:PresentingTheChangelogOverlay>
- <doc:CustomizingAppearance>
