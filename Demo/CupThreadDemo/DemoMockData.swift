import Foundation

// Mock fixtures served by `DemoMockURLProtocol`, kept in their own file so
// the URLProtocol plumbing and the canned responses stay under the lint
// file-size budget.

// MARK: - Mock Data Container

enum DemoMockData {
    private static func encodeJSON(_ obj: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    }

    static var appConfigJSON: Data {
        encodeJSON([
            "appId": "app_demo_1",
            "appKey": "app_demo_placeholder",
            "slug": "cupthread-demo",
            "name": "CupThread Demo",
            "storeUrl": "https://apps.apple.com",
            "storeKind": "app_store",
            "allowPublic": true,
            "allowedPlatforms": ["ios", "macos", "universal"],
            "maxAttachmentBytes": 20_000_000,
            "allowAnonymousRoadmap": true,
            "allowAnonymousVote": true,
            "allowAnonymousFeedback": true,
            "allowAnonymousChangelog": true,
            "sdk": [
                "theme": "system",
                "features": [
                    "roadmap": true,
                    "featureRequests": true,
                    "changelog": true,
                    "feedback": true
                ],
                "changelogOverlay": [
                    "title": "What's New in v2.4",
                    "subtitle": "Discover the latest improvements and features in CupThread.",
                    "primaryButton": "Got It",
                    "closeButton": "Close",
                    "entryCount": 3
                ]
            ]
        ])
    }

    static var columnsJSON: Data {
        encodeJSON([
            "columns": [
                [
                    "id": "col_planned",
                    "appId": "app_demo_1",
                    "name": "Planned",
                    "slug": "planned",
                    "position": 1,
                    "isVisible": true,
                    "isSystem": false,
                    "kind": "normal",
                    "createdAt": "2026-01-01T00:00:00Z",
                    "updatedAt": "2026-01-01T00:00:00Z"
                ],
                [
                    "id": "col_in_progress",
                    "appId": "app_demo_1",
                    "name": "In Progress",
                    "slug": "in-progress",
                    "position": 2,
                    "isVisible": true,
                    "isSystem": false,
                    "kind": "normal",
                    "createdAt": "2026-01-01T00:00:00Z",
                    "updatedAt": "2026-01-01T00:00:00Z"
                ],
                [
                    "id": "col_completed",
                    "appId": "app_demo_1",
                    "name": "Completed",
                    "slug": "completed",
                    "position": 3,
                    "isVisible": true,
                    "isSystem": true,
                    "kind": "done",
                    "createdAt": "2026-01-01T00:00:00Z",
                    "updatedAt": "2026-01-01T00:00:00Z"
                ]
            ]
        ])
    }

    static var versionsJSON: Data {
        encodeJSON([
            "versions": [
                [
                    "id": "ver_2_4_0",
                    "appId": "app_demo_1",
                    "label": "v2.4.0",
                    "position": 1,
                    "released": true,
                    "releasedAt": "2026-08-20T10:00:00Z",
                    "description": "Liquid Glass design and performance improvements",
                    "createdAt": "2026-08-01T00:00:00Z",
                    "updatedAt": "2026-08-20T10:00:00Z"
                ],
                [
                    "id": "ver_2_5_0",
                    "appId": "app_demo_1",
                    "label": "v2.5.0",
                    "position": 2,
                    "released": false,
                    "description": "Interactive widgets and offline synchronization",
                    "createdAt": "2026-08-15T00:00:00Z",
                    "updatedAt": "2026-08-15T00:00:00Z"
                ]
            ]
        ])
    }

    static var allFeatureRequestsJSON: Data {
        encodeJSON([
            "requests": [
                [
                    "id": "req_1",
                    "appId": "app_demo_1",
                    "title": "Interactive Lock & Home Screen Widgets",
                    "description": "Add Lock Screen widgets to track roadmap status and upvote features.",
                    "status": "in-progress",
                    "columnId": "col_in_progress",
                    "columnSlug": "in-progress",
                    "columnName": "In Progress",
                    "versionId": "ver_2_5_0",
                    "versionLabel": "v2.5.0",
                    "requesterName": "Sarah Connor",
                    "requesterAvatarUrl": "https://images.unsplash.com/photo-1494790108377-be9c29b29330?w=128&h=128&fit=crop",
                    "recentCommenters": [
                        [
                            "authorName": "David Miller",
                            "avatarUrl": "https://images.unsplash.com/photo-1507003211169-0a1dd7228f2d?w=128&h=128&fit=crop"
                        ],
                        [
                            "authorName": "Elena Rostova",
                            "avatarUrl": "https://images.unsplash.com/photo-1438761681033-6461ffad8d80?w=128&h=128&fit=crop"
                        ]
                    ],
                    "hasMoreCommenters": true,
                    "approved": true,
                    "voteCount": 142,
                    "hasVoted": true,
                    "isOwnRequest": false,
                    "createdAt": "2026-08-15T08:30:00Z",
                    "updatedAt": "2026-08-25T14:20:00Z"
                ],
                [
                    "id": "req_2",
                    "appId": "app_demo_1",
                    "title": "Offline Draft Caching & Automatic Sync",
                    "description": "Allow composing feedback offline with background synchronization once network is restored.",
                    "status": "in-progress",
                    "columnId": "col_in_progress",
                    "columnSlug": "in-progress",
                    "columnName": "In Progress",
                    "versionId": "ver_2_5_0",
                    "versionLabel": "v2.5.0",
                    "requesterName": "David Miller",
                    "requesterAvatarUrl": "https://images.unsplash.com/photo-1507003211169-0a1dd7228f2d?w=128&h=128&fit=crop",
                    "recentCommenters": [
                        [
                            "authorName": "Michael Scott",
                            "avatarUrl": "https://images.unsplash.com/photo-1500648767791-00dcc994a43e?w=128&h=128&fit=crop"
                        ]
                    ],
                    "hasMoreCommenters": false,
                    "approved": true,
                    "voteCount": 98,
                    "hasVoted": false,
                    "isOwnRequest": false,
                    "createdAt": "2026-08-10T14:15:00Z",
                    "updatedAt": "2026-08-22T09:10:00Z"
                ],
                [
                    "id": "req_3",
                    "appId": "app_demo_1",
                    "title": "Export Feedback Threads to CSV & PDF",
                    "description": "Allow exporting feedback threads with metadata to CSV and PDF for stakeholder reviews.",
                    "status": "completed",
                    "columnId": "col_completed",
                    "columnSlug": "completed",
                    "columnName": "Completed",
                    "versionId": "ver_2_4_0",
                    "versionLabel": "v2.4.0",
                    "releasedVersion": "2.4.0",
                    "requesterName": "Elena Rostova",
                    "approved": true,
                    "voteCount": 85,
                    "hasVoted": false,
                    "isOwnRequest": false,
                    "createdAt": "2026-07-28T09:00:00Z",
                    "updatedAt": "2026-08-20T10:00:00Z"
                ],
                [
                    "id": "req_4",
                    "appId": "app_demo_1",
                    "title": "Apple Pencil & Scribble Annotation",
                    "description": "Support drawing annotations on screenshots and handwriting inside composer.",
                    "status": "planned",
                    "columnId": "col_planned",
                    "columnSlug": "planned",
                    "columnName": "Planned",
                    "requesterName": "Michael Scott",
                    "approved": true,
                    "voteCount": 64,
                    "hasVoted": false,
                    "isOwnRequest": false,
                    "createdAt": "2026-08-01T11:20:00Z",
                    "updatedAt": "2026-08-18T16:40:00Z"
                ],
                [
                    "id": "req_5",
                    "appId": "app_demo_1",
                    "title": "Biometric Authentication for Admin Feedback",
                    "description": "Require Face ID authentication before viewing or replying to confidential feedback categories.",
                    "status": "planned",
                    "columnId": "col_planned",
                    "columnSlug": "planned",
                    "columnName": "Planned",
                    "requesterName": "Clara Oswald",
                    "approved": true,
                    "voteCount": 39,
                    "hasVoted": false,
                    "isOwnRequest": false,
                    "createdAt": "2026-08-05T16:45:00Z",
                    "updatedAt": "2026-08-19T11:05:00Z"
                ]
            ],
            "total": 5
        ])
    }

    static var voteJSON: Data {
        encodeJSON([
            "featureRequestId": "req_1",
            "voteCount": 143,
            "hasVoted": true
        ])
    }

    static var changelogJSON: Data {
        encodeJSON([
            "entries": [
                [
                    "id": "chg_2_4_0",
                    "title": "Version 2.4.0 — Liquid Glass & Enhanced Export",
                    "body": "Welcome to **CupThread 2.4.0**! Refreshed visuals, faster search, and export tools.\n\n"
                        + "- **Export to CSV & PDF**: Export feedback threads directly from the app.\n"
                        + "- **Liquid Glass**: Refined native appearance on iOS, macOS, and visionOS.\n"
                        + "- **Instant Search**: Real-time search across all roadmap stages.",
                    "versionLabel": "2.4.0",
                    "publishedAt": "2026-08-20T10:00:00Z",
                    "linkedRequests": [
                        [
                            "id": "req_3",
                            "title": "Export Feedback Threads to CSV & PDF"
                        ]
                    ]
                ],
                [
                    "id": "chg_2_3_0",
                    "title": "Version 2.3.0 — Attachments & visionOS Support",
                    "body": "We are excited to introduce rich attachment uploads and native visionOS support.\n\n"
                        + "- **Media Uploads**: Attach screenshots and crash logs to feedback drafts.\n"
                        + "- **Spatial Computing**: Fully native visionOS spatial window depth.",
                    "versionLabel": "2.3.0",
                    "publishedAt": "2026-07-15T09:30:00Z",
                    "linkedRequests": []
                ]
            ]
        ])
    }

    static var submitFeedbackJSON: Data {
        encodeJSON([
            "id": "sub_demo_123456",
            "title": "Demo feedback",
            "status": "queued",
            "createdAt": "2026-09-13T12:00:00Z"
        ])
    }

    static var uploadSessionJSON: Data {
        encodeJSON([
            "session": [
                "sessionId": "sess_demo_1",
                "sessionToken": "demo-session-token",
                "expiresAt": "2026-09-13T18:00:00Z",
                "maxFileSizeBytes": 20_000_000,
                "maxFiles": 8
            ],
            "files": [[
                "clientFileId": "file-1",
                "uploadId": "upl_demo_1",
                "uploadUrl": "https://api.cupthread.com/api/v1/uploads/upl_demo_1",
                "maxSizeBytes": 20_000_000
            ]]
        ])
    }

    static var uploadedFileJSON: Data {
        encodeJSON([
            "uploadId": "upl_demo_1",
            "clientFileId": "file-1",
            "filename": "screenshot.png",
            "contentType": "image/png",
            "sizeBytes": 42,
            "sha256": "demo",
            "stored": true,
            "downloadUrl": NSNull()
        ])
    }

    static var submitFeatureRequestJSON: Data {
        encodeJSON([
            "featureRequestId": "req_demo_new_1",
            "pending": false
        ])
    }

    /// The production Turnstile-gate rejection envelope (issue #53): the
    /// human-readable message plus the machine-readable `code` the SDK's
    /// typed-error mapping keys on — `turnstile_required` on the intake
    /// endpoints, `turnstile_verification_failed` on upload sessions.
    static func turnstileGateRejectionJSON(code: String) -> Data {
        encodeJSON([
            "error": "Human verification (Turnstile) is required",
            "code": code
        ])
    }

    static var subscribeJSON: Data {
        encodeJSON([
            "success": true
        ])
    }

    static var unsubscribeJSON: Data {
        encodeJSON([
            "unsubscribed": true
        ])
    }

    static var userAttributesJSON: Data {
        encodeJSON([
            "ok": true,
            "updatedAt": "2026-08-31T12:00:00Z"
        ])
    }
}
