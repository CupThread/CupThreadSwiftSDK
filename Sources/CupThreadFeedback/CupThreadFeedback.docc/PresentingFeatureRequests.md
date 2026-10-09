# Presenting Feature Requests

Give your users a voice with real-time search, optimistic voting, milestone filtering, and submission sheets.

![Browse Feature Requests](feature_requests.jpg)

## Overview

``FeatureRequestsView`` is a full-featured surface where users can discover what others have suggested, vote on their favorite ideas, and submit new feature requests.

![Submit Feature Request](submit_request.jpg)

Key features:
- **Optimistic voting**: Immediate UI response with background server synchronization and duplicate click throttling.
- **Real-time search**: Debounced search querying the CupThread backend.
- **Version filtering**: Filter requests by targeted milestone release versions.
- **Anonymous user identity**: Managed by ``UserTokenStore`` (scoped per app key) so upvotes and submissions persist across app restarts without user login.

## Basic usage

Embed ``FeatureRequestsView`` in a `NavigationStack` with your client and user token:

```swift
import SwiftUI
import CupThreadFeedback

struct FeatureRequestsTab: View {
    let client: FeedbackClient
    let tokenStore = UserTokenStore(appKey: "app_xxx")

    var body: some View {
        NavigationStack {
            FeatureRequestsView(
                client: client,
                userToken: tokenStore.token
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
    userToken: tokenStore.token,
    autoPresentCompose: true
)
```

## Pre-filled search

You can pre-filter requests to a specific topic or component:

```swift
FeatureRequestsView(
    client: client,
    userToken: tokenStore.token,
    initialSearchText: "Widgets"
)
```

## Pagination

The list loads the first page of matching requests and fetches further pages automatically as the end of the list scrolls into view. The trailing row doubles as an explicit retry when a page fails to load; already-loaded requests stay on screen either way. Changing the search text or the version filter restarts from the first page of the new filter.

## Platform adaptations

``FeatureRequestsView`` tailors its presentation for each Apple platform:
- **iOS, iPadOS, macOS, visionOS**: Card-based layout with interactive vote badges and markdown-rendered descriptions.
- **tvOS**: A focus-friendly list optimized for Siri Remote navigation.

## Comments and sign-in

Feature request threads support flat comments with @replies through ``CommentsView``. Comment creation is signed-in-only on the CupThread API: anonymous callers receive `401 authentication_required`, mapped to ``FeedbackClientError/authenticationRequired``.

Provide an authentication provider when creating the client so signed-in users can contribute. The provider resolves the signed-in user's current bearer token on every authenticated call — refresh it there when it is about to expire — and the SDK presents it as `Authorization: Bearer …`. The anonymous `X-User-Token` correlation header is still sent:

```swift
let client = FeedbackClient(
    configuration: configuration,
    authenticationProvider: {
        await authController.currentBearerToken()
    }
)
```

In addition to comment creation, the authentication provider attaches the bearer token to read and subscribe endpoints (loading comments, feature requests, roadmap columns, versions, and changelog) so signed-in users continue to have access even when the console disables anonymous access for the app (`allowAnonymousRoadmap` or `allowAnonymousChangelog`).

When the provider resolves `nil` (signed out) or the client has none, ``CommentsView`` shows a deliberate signed-out notice instead of a composer that could never succeed, and direct ``FeedbackClient/postComment(featureRequestId:draft:userToken:)`` calls throw the typed error. The author's display name and avatar always resolve server-side from the signed-in profile. Avatar and app-icon URLs from the API are treated as untrusted and filtered by `WebURLPolicy` to require HTTPS and prevent outbound requests to insecure or disallowed schemes.

## Human verification (Turnstile)

Like feedback submission, feature-request submission is gated behind Cloudflare Turnstile in production: ``FeedbackClient/submitFeatureRequest(_:userToken:)`` can only succeed when the client presents a verification token. Browsing, search, voting, and comment threads are not gated, so the view works without any verification setup — but submitting a new request fails with ``FeedbackClientError/turnstileRequired(message:requestId:)`` until the client is created with a `turnstileTokenProvider`.

The provider is consulted with the ``TurnstileAction/featureRequest`` binding (the app key as `cdata`), so render the widget — or mint the token server-side — under exactly that action. The bindings are endpoint-specific: the feedback action covers `POST /api/v1/feedback` and attachment upload sessions, and a feedback-minted token is rejected on feature-request submission. When the server rejects the submission with the verification gate (HTTP 403), the SDK asks the provider for a fresh token under the same binding and retries exactly once before surfacing the typed error:

```swift
let client = FeedbackClient(
    configuration: configuration,
    turnstileTokenProvider: { challenge in
        // `challenge.action` is TurnstileAction.featureRequest and
        // `challenge.cdata` is the app key — render (or server-mint) the
        // token under exactly this pair, e.g. turnstile.render({
        // action: challenge.action, cdata: challenge.cdata }).
        await MyVerificationCoordinator.currentToken(for: challenge)
    }
)
```

Without a provider, a gated submission fails after a single attempt with a localized, user-safe message instead of the raw server response. The shared provider contract — bindings, retry semantics, and host verification flows — is described in <doc:PresentingFeedbackComposer>.

## See also

- ``FeatureRequestsView``
- ``FeatureRequestItem``
- ``FeatureRequestDraft``
- ``VoteResult``
- <doc:PresentingTheRoadmap>
- <doc:GettingStarted>
