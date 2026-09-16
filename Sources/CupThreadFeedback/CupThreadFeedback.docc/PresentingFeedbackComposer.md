# Presenting the Feedback Composer

Collect structured bug reports, feedback, and user ideas with automatic environment diagnostics and attachment uploads.

![CupThread Feedback Composer](feedback_composer.jpg)

## Overview

``FeedbackComposerView`` provides a ready-made SwiftUI feedback form that handles input validation, platform diagnostics, attachment management, and server submission out of the box.

The form automatically captures:
- **Platform**: The surface the form runs on (iOS, macOS, visionOS, or tvOS).
- **App version & build**: Pulled from `Bundle.main`.
- **Optional contact info**: Name and email, typed by the user and cleared after each successful submission.
- **Attachments**: Images picked from the user's photo library, uploaded through upload sessions to CupThread storage (photo attachments have sensitive EXIF and GPS location metadata stripped before upload to protect user privacy while preserving multi-frame animations like GIF and animated WebP intact, and HEIC photos are transcoded to JPEG — the API accepts PNG, JPEG, WebP, and GIF only).

## Basic usage

Wrap the composer in a `NavigationStack` and present it in a sheet or navigation destination:

```swift
import SwiftUI
import CupThreadFeedback

struct FeedbackSheet: View {
    let client: FeedbackClient
    @Environment(\.dismiss) private var dismiss
    let tokenStore = UserTokenStore(appKey: "app_xxx")

    var body: some View {
        NavigationStack {
            FeedbackComposerView(
                client: client,
                userToken: tokenStore.token,
                onSubmit: { result in
                    print("Feedback submitted: \(result.submissionId)")
                    dismiss()
                }
            )
        }
    }
}
```

## Pre-filling drafts

You can pre-fill any part of the draft before presenting the form, such as appending custom diagnostics to the free-form ``FeedbackDraft/metadata`` dictionary for your own triage tooling:

```swift
var draft = FeedbackDraft.autofilled()
draft.title = "Crash on checkout"
draft.description = "Steps to reproduce:\n1. Open cart\n2. Tap pay"
draft.metadata = ["plan": "pro", "tier": "gold"]

FeedbackComposerView(
    client: client,
    initialDraft: draft,
    userToken: tokenStore.token
)
```

## Programmatic submissions

If you build your own custom feedback UI, you can use ``FeedbackClient`` directly without using ``FeedbackComposerView``:

```swift
// 1. (Optional) Upload an attachment
let attachment = try await client.uploadAttachment(
    data: screenshotData,
    filename: "screenshot.png",
    mimeType: "image/png",
    userToken: tokenStore.token
)

// 2. Prepare the draft
var draft = FeedbackDraft.autofilled()
draft.title = "Love the new update!"
draft.description = "The new dark mode looks fantastic."
draft.attachments = [attachment]

// 3. Submit
let result = try await client.submit(draft, userToken: tokenStore.token)
print("Submitted ID: \(result.submissionId)")
```

## Attachment upload lifecycle

Attachment uploads are deliberately independent of the composer's view lifecycle:

- **Transient disappearances never cancel an upload.** Pushing a view on top of the composer inside a `NavigationStack`, or switching `TabView` tabs, leaves an in-flight photo upload running. When the user comes back, the attachment row shows the upload still in progress, or the finished attachment.
- **Cancellation is explicit.** Uploads stop only at user-intent-bearing points: the cancel button on the uploading row, a superseding photo selection, and the form reset after a successful submit.
- **Real dismissal finishes in the background.** If the composer is dismissed entirely while an upload is running, the upload finishes in the background and its result is discarded along with the destroyed draft.

Hosts that prefer to stop the transfer when the composer is really dismissed can pass a ``FeedbackUploadHandle`` and call ``FeedbackUploadHandle/cancelActiveUpload()`` from the presentation context's `onDismiss` closure:

```swift
struct FeedbackSheet: View {
    let client: FeedbackClient
    @State private var isPresented = false
    private let uploadHandle = FeedbackUploadHandle()

    var body: some View {
        Button("Send Feedback") { isPresented = true }
            .sheet(isPresented: $isPresented, onDismiss: {
                uploadHandle.cancelActiveUpload()
            }) {
                NavigationStack {
                    FeedbackComposerView(client: client, uploadHandle: uploadHandle)
                }
            }
    }
}
```

## See also

- ``FeedbackComposerView``
- ``FeedbackUploadHandle``
- ``FeedbackDraft``
- ``FeedbackAttachment``
- ``FeedbackSubmissionResult``
- <doc:GettingStarted>
- <doc:CustomizingAppearance>
