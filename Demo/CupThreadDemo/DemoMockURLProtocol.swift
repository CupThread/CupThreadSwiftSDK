import Foundation

/// URLProtocol subclass that mocks all CupThread API requests for Demo and UI tests.
final class DemoMockURLProtocol: URLProtocol, @unchecked Sendable {

    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        // Intercept requests to cupthread domains or any mock requests
        return url.host?.contains("cupthread") == true
            || url.host?.contains("localhost") == true
            || url.host?.contains("127.0.0.1") == true
    }

    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let path = url.path
        let query = url.query ?? ""

        let (statusCode, data) = Self.response(for: path, query: query, method: request.httpMethod ?? "GET")

        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/json",
                "Access-Control-Allow-Origin": "*"
            ]
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func response(for path: String, query: String, method: String) -> (Int, Data) {
        if path.contains("/api/v1/public/config/") {
            return (200, DemoMockData.appConfigJSON)
        }
        if path.contains("/api/v1/public/columns/") {
            return (200, DemoMockData.columnsJSON)
        }
        if path.contains("/api/v1/public/versions/") {
            return (200, DemoMockData.versionsJSON)
        }
        if path.contains("/api/v1/feature-requests") {
            return handleFeatureRequests(path: path, query: query, method: method)
        }
        if path.contains("/api/v1/public/apps/") {
            return handleAppsPublic(path: path)
        }
        if path.contains("/api/v1/feedback") {
            return (200, DemoMockData.submitFeedbackJSON)
        }
        return (200, Data("{}".utf8))
    }

    private static func handleFeatureRequests(path: String, query: String, method: String) -> (Int, Data) {
        if path.contains("/vote") {
            return (200, DemoMockData.voteJSON)
        }
        if method == "POST" {
            return (201, DemoMockData.submitFeatureRequestJSON)
        }
        return (200, DemoMockData.allFeatureRequestsJSON)
    }

    private static func handleAppsPublic(path: String) -> (Int, Data) {
        if path.contains("/changelog/subscribe") {
            return (200, DemoMockData.subscribeJSON)
        }
        if path.contains("/changelog/unsubscribe") {
            return (200, DemoMockData.unsubscribeJSON)
        }
        if path.contains("/changelog") {
            return (200, DemoMockData.changelogJSON)
        }
        if path.contains("/user") {
            return (200, DemoMockData.userAttributesJSON)
        }
        return (200, Data("{}".utf8))
    }
}

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
            "voted": true,
            "voteCount": 143
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
            "submissionId": "sub_demo_123456"
        ])
    }

    static var submitFeatureRequestJSON: Data {
        encodeJSON([
            "featureRequestId": "req_demo_new_1",
            "pending": false
        ])
    }

    static var subscribeJSON: Data {
        encodeJSON([
            "subscribed": true,
            "alreadySubscribed": false
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
