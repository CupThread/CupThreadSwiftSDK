import Foundation
import Testing
@testable import CupThreadFeedback

/// Regression pins for issue #26: the reserved submission metadata keys
/// (`sdk`, `sdkVersion`, `platform`, `submittedAt`) are SDK-authored on the
/// wire, mirroring the Android SDK reference merge where the SDK map
/// overwrites host draft metadata. Host drafts may add custom keys but
/// cannot replace the reserved ones.
@Suite("FeedbackReservedMetadataOverride", .serialized)
struct FeedbackReservedMetadataOverrideTests {
    static let apiHost = "metadata-override.example.com"

    @Test func spoofedReservedKeysAreReplacedWithSdkValuesOnTheWire() async throws {
        let capture = CaptureBox<Data>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = bodyData(from: request)
            return (makeHTTPResponse(), try encodeJSON(["submissionId": "s-1", "forwardedToGithub": true]))
        }

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!, appKey: "app_metadatatest01")
        let draft = FeedbackDraft(
            title: "Spoof attempt",
            description: "Draft metadata tries to override the reserved SDK keys",
            platform: .ios,
            metadata: [
                "sdk": "spoofed-sdk",
                "sdkVersion": "9.9.9",
                "platform": "android",
                "submittedAt": "1970-01-01T00:00:00Z",
                "deviceModel": "iPhone 15 Pro",
                "reproSteps": "1. Open composer 2. Attach photo"
            ]
        )
        _ = try await client.submit(draft)

        let rawData = try #require(capture.value)
        let json = try #require(parseJSONDict(rawData))
        let metadata = try #require(json["metadata"] as? [String: String])
        #expect(metadata["sdk"] == "cupthread-apple/\(FeedbackClient.sdkVersion)")
        #expect(metadata["sdkVersion"] == FeedbackClient.sdkVersion)
        #expect(metadata["platform"] == draft.platform.rawValue)
        #expect(metadata["deviceModel"] == "iPhone 15 Pro")
        #expect(metadata["reproSteps"] == "1. Open composer 2. Attach photo")
        // Exactly the 4 SDK-authored reserved keys plus the 2 custom keys —
        // no spoofed entry survived under any name.
        #expect(metadata.count == 6)
    }

    @Test func wireSubmittedAtIsSdkAuthoredNotTheSpoofedEpoch() async throws {
        let capture = CaptureBox<Data>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = bodyData(from: request)
            return (makeHTTPResponse(), try encodeJSON(["submissionId": "s-1", "forwardedToGithub": true]))
        }

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!, appKey: "app_metadatatest01")
        let draft = FeedbackDraft(
            title: "T",
            description: "D",
            platform: .macos,
            metadata: ["submittedAt": "1970-01-01T00:00:00Z"]
        )
        _ = try await client.submit(draft)

        let rawData = try #require(capture.value)
        let json = try #require(parseJSONDict(rawData))
        let metadata = try #require(json["metadata"] as? [String: String])
        let wireSubmittedAt = try #require(metadata["submittedAt"])
        #expect(wireSubmittedAt != "1970-01-01T00:00:00Z")
        let parsed = try #require(ISO8601DateFormatter().date(from: wireSubmittedAt))
        #expect(parsed.timeIntervalSince1970 > 0)
    }

    @Test func sanitizerPrefersReservedValuesForEveryReservedKeyName() {
        let sanitized = FeedbackMetadataSanitizer.sanitize(
            [
                "sdk": "spoofed-sdk",
                "sdkVersion": "9.9.9",
                "platform": "android",
                "submittedAt": "1970-01-01T00:00:00Z"
            ],
            reserved: [
                "sdk": FeedbackClient.sdkIdentifier,
                "sdkVersion": FeedbackClient.sdkVersion,
                "platform": "ios",
                "submittedAt": "2026-09-18T00:00:00Z"
            ]
        )
        #expect(sanitized["sdk"] == FeedbackClient.sdkIdentifier)
        #expect(sanitized["sdkVersion"] == FeedbackClient.sdkVersion)
        #expect(sanitized["platform"] == "ios")
        #expect(sanitized["submittedAt"] == "2026-09-18T00:00:00Z")
    }

    @Test func sanitizerDropsSpoofedReservedKeysUnderKeyCountEviction() {
        var hostMetadata: [String: String] = [
            "sdk": "spoofed-sdk",
            "sdkVersion": "9.9.9",
            "platform": "android",
            "submittedAt": "1970-01-01T00:00:00Z"
        ]
        for index in 0..<30 {
            hostMetadata[String(format: "hostKey%02d", index)] = "v\(index)"
        }
        let reserved = [
            "sdk": FeedbackClient.sdkIdentifier,
            "sdkVersion": FeedbackClient.sdkVersion,
            "platform": "ios",
            "submittedAt": "2026-09-18T00:00:00Z"
        ]

        let sanitized = FeedbackMetadataSanitizer.sanitize(hostMetadata, reserved: reserved)
        #expect(sanitized["sdk"] == FeedbackClient.sdkIdentifier)
        #expect(sanitized["sdkVersion"] == FeedbackClient.sdkVersion)
        #expect(sanitized["platform"] == "ios")
        #expect(sanitized["submittedAt"] == "2026-09-18T00:00:00Z")
        #expect(sanitized.count == FeedbackMetadataSanitizer.maxKeys)
    }
}
