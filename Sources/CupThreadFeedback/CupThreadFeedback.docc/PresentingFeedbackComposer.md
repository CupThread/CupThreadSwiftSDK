# Presenting the Feedback Composer

Collect structured bug reports, feedback, and user ideas with automatic environment diagnostics and attachment uploads.

![CupThread Feedback Composer](feedback_composer.webp)

## Overview

``FeedbackComposerView`` provides a ready-made SwiftUI feedback form that handles input validation, platform diagnostics, attachment management, and server submission out of the box.

The form automatically captures:
- **Device & OS version**: e.g., iOS 17.5, macOS 14.4.
- **App version & build**: Pulled from `Bundle.main`.
- **System locale & time zone**.
- **Optional contact info**: Name and email (remembered between submissions).
- **Attachments**: Images and log files uploaded to CupThread storage.

## Basic usage

Wrap the composer in a `NavigationStack` and present it in a sheet or navigation destination:

```swift
import SwiftUI
import CupThreadFeedback

struct FeedbackSheet: View {
    let client: FeedbackClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            FeedbackComposerView(
                client: client,
                userToken: UserTokenStore.shared.token,
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

You can pre-fill any part of the draft before presenting the form, such as appending custom diagnostics or logs to the draft:

```swift
var draft = FeedbackDraft.autofilled()
draft.title = "Crash on checkout"
draft.description = "Steps to reproduce:\n1. Open cart\n2. Tap pay"
draft.customMetadata = ["plan": "pro", "tier": "gold"]

FeedbackComposerView(
    client: client,
    initialDraft: draft,
    userToken: UserTokenStore.shared.token
)
```

## Programmatic submissions

If you build your own custom feedback UI, you can use ``FeedbackClient`` directly without using ``FeedbackComposerView``:

```swift
// 1. (Optional) Upload an attachment
let attachment = try await client.uploadAttachment(
    data: screenshotData,
    filename: "screenshot.png",
    mimeType: "image/png"
)

// 2. Prepare the draft
var draft = FeedbackDraft.autofilled()
draft.title = "Love the new update!"
draft.description = "The new dark mode looks fantastic."
draft.attachments = [attachment]

// 3. Submit
let result = try await client.submit(draft, userToken: UserTokenStore.shared.token)
print("Submitted ID: \(result.submissionId)")
```

## See also

- ``FeedbackComposerView``
- ``FeedbackDraft``
- ``FeedbackAttachment``
- ``FeedbackSubmissionResult``
- <doc:GettingStarted>
- <doc:CustomizingAppearance>
