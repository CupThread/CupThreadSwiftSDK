import Foundation
import Testing
@testable import CupThreadFeedback

@Suite("FeedbackMetadataSanitizer")
struct FeedbackMetadataSanitizerSuite {
    @Test func parityWithServerSensitiveKeyContract() {
        let fixtures: [(key: String, isSensitive: Bool)] = [
            ("author", false),
            ("authorName", false),
            ("authorEmail", false),
            ("authoredAt", false),
            ("oauthState", false),
            ("sessionCount", true),
            ("authToken", true),
            ("jwt", true),
            ("bearer", true),
            ("signature", true),
            ("ssn", true),
            ("SECRET", true),
            ("github_token", true),
            ("sessionCookie", true),
            ("accessKey", true),
            ("creditCard", true),
            ("privateKey", true),
            ("otp", true),
            ("passwordHint", true),
            ("API_KEY", true),
            ("user-password", true),
            ("cookie", true),
            ("authorization", true),
            ("note", false),
            ("design", false),
            ("signal", false),
            ("compass", false),
            ("passport", false),
            ("bypass", false)
        ]

        for fixture in fixtures {
            #expect(
                FeedbackMetadataSanitizer.isCredentialKey(fixture.key) == fixture.isSensitive,
                "Key '\(fixture.key)' sensitive verdict mismatch"
            )
        }
    }

    @Test func preservesAuthorKeysAndRedactsServerSensitiveKeys() {
        let sanitized = FeedbackMetadataSanitizer.sanitize([
            "author": "Lex",
            "authorName": "Lex Tang",
            "authorEmail": "lex@example.com",
            "authoredAt": "2026-09-15T00:00:00Z",
            "oauthState": "state123",
            "sessionCount": "42",
            "jwt": "header.payload.signature",
            "bearer": "tok_xyz",
            "signature": "sig_abc",
            "ssn": "000-00-0000"
        ])
        #expect(sanitized["author"] == "Lex")
        #expect(sanitized["authorName"] == "Lex Tang")
        #expect(sanitized["authorEmail"] == "lex@example.com")
        #expect(sanitized["authoredAt"] == "2026-09-15T00:00:00Z")
        #expect(sanitized["oauthState"] == "state123")
        #expect(sanitized["sessionCount"] == "[redacted]")
        #expect(sanitized["jwt"] == "[redacted]")
        #expect(sanitized["bearer"] == "[redacted]")
        #expect(sanitized["signature"] == "[redacted]")
        #expect(sanitized["ssn"] == "[redacted]")
    }

    @Test func evictionWithThirtyHostKeysPreservesReservedKeys() {
        var metadata: [String: String] = [:]
        for index in 0..<30 {
            metadata[String(format: "hostKey%02d", index)] = "v\(index)"
        }
        metadata["sdk"] = "cupthread-apple"
        metadata["platform"] = "ios"
        metadata["submittedAt"] = "2026-09-15T00:00:00Z"

        let sanitized = FeedbackMetadataSanitizer.sanitize(metadata)
        #expect(sanitized.count == 24)
        #expect(sanitized["sdk"] == "cupthread-apple")
        #expect(sanitized["platform"] == "ios")
        #expect(sanitized["submittedAt"] == "2026-09-15T00:00:00Z")
        // 21 host keys survive (hostKey00...hostKey20) + 3 reserved keys = 24
        #expect(sanitized["hostKey00"] == "v0")
        #expect(sanitized["hostKey20"] == "v20")
        #expect(sanitized["hostKey21"] == nil)
    }

    @Test func evictionWithExplicitReservedDictionaryPreservesReservedKeys() {
        var hostMetadata: [String: String] = [:]
        for index in 0..<30 {
            hostMetadata[String(format: "hostKey%02d", index)] = "v\(index)"
        }
        let reserved = [
            "sdk": "cupthread-apple",
            "platform": "macos",
            "submittedAt": "2026-09-15T00:00:00Z"
        ]

        let sanitized = FeedbackMetadataSanitizer.sanitize(hostMetadata, reserved: reserved)
        #expect(sanitized.count == 24)
        #expect(sanitized["sdk"] == "cupthread-apple")
        #expect(sanitized["platform"] == "macos")
        #expect(sanitized["submittedAt"] == "2026-09-15T00:00:00Z")
        #expect(sanitized["hostKey00"] == "v0")
        #expect(sanitized["hostKey20"] == "v20")
        #expect(sanitized["hostKey21"] == nil)
    }

    @Test func evictionUnderByteBudgetPreservesReservedKeysFirst() {
        var hostMetadata: [String: String] = [:]
        for index in 0..<24 {
            hostMetadata[String(format: "hostKey%02d", index)] = String(repeating: "z", count: 400)
        }
        let reserved = [
            "sdk": "cupthread-apple",
            "platform": "ios",
            "submittedAt": "2026-09-15T00:00:00Z"
        ]

        let sanitized = FeedbackMetadataSanitizer.sanitize(hostMetadata, reserved: reserved)
        let serialized = try? JSONEncoder().encode(sanitized)
        #expect((serialized?.count ?? .max) <= FeedbackMetadataSanitizer.maxTotalBytes)
        #expect(sanitized["sdk"] == "cupthread-apple")
        #expect(sanitized["platform"] == "ios")
        #expect(sanitized["submittedAt"] == "2026-09-15T00:00:00Z")
    }

    @Test func hostCannotOverrideSdkReservedKeys() {
        let hostMetadata = [
            "sdk": "spoofed-sdk",
            "platform": "android",
            "submittedAt": "1970-01-01T00:00:00Z"
        ]
        let reserved = [
            "sdk": "cupthread-apple",
            "platform": "ios",
            "submittedAt": "2026-09-15T00:00:00Z"
        ]

        let sanitized = FeedbackMetadataSanitizer.sanitize(hostMetadata, reserved: reserved)
        #expect(sanitized["sdk"] == "cupthread-apple")
        #expect(sanitized["platform"] == "ios")
        #expect(sanitized["submittedAt"] == "2026-09-15T00:00:00Z")
    }
}
