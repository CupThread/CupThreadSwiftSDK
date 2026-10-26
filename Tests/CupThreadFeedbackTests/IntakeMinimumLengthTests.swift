import Foundation
import Testing
@testable import CupThreadFeedback

// Issue #415 (BUG-32): the headless programmatic intake methods
// (`FeedbackClient.submit` and `FeedbackClient.submitFeatureRequest`) only
// trimmed `title`/`description` before dispatching, so whitespace-only or
// sub-minimum drafts consumed a Turnstile challenge token and a network
// round trip only to be answered with `400 Validation failed` — the UI form
// gates (`canSubmit`) enforce the same minimums but headless callers had no
// equivalent. Both methods now reject such drafts locally, before the
// Turnstile provider is consulted or any request is built.
@Suite("Intake Minimum Length", .serialized)
struct IntakeMinimumLengthTests {
    static let apiHost = "intake-minimums.example.com"

    /// Thread-safe counter recording every Turnstile provider consultation.
    final class ProviderCallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0

        func record() -> String? {
            lock.lock()
            defer { lock.unlock() }
            calls += 1
            return "turnstile-token"
        }

        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }

    /// A client whose Turnstile provider and network host both record every
    /// consultation, so a local rejection can prove neither was reached.
    static func makeCountingClient() -> (FeedbackClient, ProviderCallCounter) {
        let counter = ProviderCallCounter()
        let client = FeedbackClient(
            configuration: FeedbackClientConfiguration(
                baseURL: URL(string: "https://\(apiHost)")!,
                appKey: "app_minimums12345"
            ),
            session: makeMockSession(),
            turnstileTokenProvider: { _ in counter.record() }
        )
        return (client, counter)
    }

    static func recordNoRequestBody() -> CaptureBox<URLRequest> {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), Data())
        }
        return capture
    }

    // MARK: - Shared bounds (IntakeTextLimits)

    @Test("underLimitField reports the first field below the server's floors, in wire order")
    func underLimitFieldReportsFirstViolatingField() {
        // Feedback drafts.
        #expect(IntakeTextLimits.underLimitField(
            in: FeedbackDraft(title: "ab", description: "Valid description", platform: .ios)
        ) == .title)
        #expect(IntakeTextLimits.underLimitField(
            in: FeedbackDraft(title: "Title", description: "abcd", platform: .ios)
        ) == .description)
        #expect(
            IntakeTextLimits.underLimitField(in: FeedbackDraft(title: "ab", description: "abcd", platform: .ios)) == .title,
            "title is checked first, in wire order"
        )
        #expect(IntakeTextLimits.underLimitField(
            in: FeedbackDraft(title: "   ", description: "\n\t", platform: .ios)
        ) == .title)
        #expect(IntakeTextLimits.underLimitField(
            in: FeedbackDraft(title: "Title", description: "Description", platform: .ios)
        ) == nil)

        // Feature-request drafts.
        #expect(IntakeTextLimits.underLimitField(in: FeatureRequestDraft(title: "ab", description: "Valid description")) == .title)
        #expect(IntakeTextLimits.underLimitField(in: FeatureRequestDraft(title: "Title", description: "abcd")) == .description)
        #expect(IntakeTextLimits.underLimitField(in: FeatureRequestDraft(title: "Title", description: "Description")) == nil)

        // Trimming decides: a padded minimum-length field meets the floor.
        #expect(IntakeTextLimits.underLimitField(in: FeedbackDraft(title: "  abc  ", description: " abcde\n", platform: .ios)) == nil)
    }

    @Test("the published minimum constants match the server's floors")
    func minimumConstantsMatchServerFloors() {
        #expect(IntakeTextLimits.minTitleLength == 3)
        #expect(IntakeTextLimits.minDescriptionLength == 5)
    }

    // MARK: - submitFeatureRequest

    @Test("submitFeatureRequest rejects whitespace-only and sub-minimum drafts locally with no Turnstile consultation and no network call")
    func submitFeatureRequestRejectsInvalidDraftsLocally() async throws {
        let capture = Self.recordNoRequestBody()
        let invalidDrafts: [(draft: FeatureRequestDraft, field: String)] = [
            (FeatureRequestDraft(title: "", description: "Valid description"), "title"),
            (FeatureRequestDraft(title: "   ", description: "Valid description"), "title"),
            (FeatureRequestDraft(title: "\n\t", description: "Valid description"), "title"),
            (FeatureRequestDraft(title: " \u{00A0} ", description: "Valid description", requesterName: "Ada"), "title"),
            (FeatureRequestDraft(title: "ab", description: "Valid description"), "title"),
            (FeatureRequestDraft(title: "Valid title", description: ""), "description"),
            (FeatureRequestDraft(title: "Valid title", description: "    "), "description"),
            (FeatureRequestDraft(title: "Valid title", description: "abcd"), "description")
        ]

        for (draft, field) in invalidDrafts {
            let (client, counter) = Self.makeCountingClient()
            await #expect(throws: FeedbackClientError.invalidInput(field: field)) {
                _ = try await client.submitFeatureRequest(draft, userToken: "user-123")
            }
            #expect(counter.callCount == 0, "An invalid draft must never consume a Turnstile token")
        }
        #expect(capture.value == nil, "An invalid draft must be rejected before any request is sent")
    }

    @Test("submitFeatureRequest accepts boundary-length drafts, trims padded fields, and consumes exactly one token")
    func submitFeatureRequestAcceptsBoundaryDrafts() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (
                makeHTTPResponse(status: 201),
                try encodeJSON(["featureRequestId": "fr-1", "pending": true])
            )
        }
        let (client, counter) = Self.makeCountingClient()

        // Exactly at every floor — the smallest drafts the server accepts.
        let atMinimum = FeatureRequestDraft(
            title: String(repeating: "t", count: IntakeTextLimits.minTitleLength),
            description: String(repeating: "d", count: IntakeTextLimits.minDescriptionLength)
        )
        let result = try await client.submitFeatureRequest(atMinimum, userToken: "user-123")
        #expect(result.featureRequestId == "fr-1")
        #expect(counter.callCount == 1, "A valid draft consumes exactly one Turnstile token")

        // Padded-but-valid drafts still dispatch and are trimmed on the wire.
        let padded = FeatureRequestDraft(title: "  abc  ", description: " abcde ")
        _ = try await client.submitFeatureRequest(padded, userToken: "user-123")
        #expect(counter.callCount == 2)

        let request = try #require(capture.value)
        let sentBody = try #require(bodyData(from: request))
        let json = try #require(parseJSONDict(sentBody))
        #expect(json["title"] as? String == "abc")
        #expect(json["description"] as? String == "abcde")
    }

    // MARK: - submit (feedback)

    @Test("submit rejects whitespace-only and sub-minimum drafts locally with no Turnstile consultation and no network call")
    func submitRejectsInvalidDraftsLocally() async throws {
        let capture = Self.recordNoRequestBody()
        let invalidDrafts: [(draft: FeedbackDraft, field: String)] = [
            (FeedbackDraft(title: "", description: "Valid description", platform: .ios), "title"),
            (FeedbackDraft(title: "   ", description: "Valid description", platform: .ios), "title"),
            (FeedbackDraft(title: "\n\t", description: "Valid description", platform: .ios), "title"),
            (FeedbackDraft(title: " \u{00A0} ", description: "Valid description", platform: .ios), "title"),
            (FeedbackDraft(title: "ab", description: "Valid description", platform: .ios), "title"),
            (FeedbackDraft(title: "Valid title", description: "", platform: .ios), "description"),
            (FeedbackDraft(title: "Valid title", description: "    ", platform: .ios), "description"),
            (FeedbackDraft(title: "Valid title", description: "abcd", platform: .ios), "description")
        ]

        for (draft, field) in invalidDrafts {
            let (client, counter) = Self.makeCountingClient()
            await #expect(throws: FeedbackClientError.invalidInput(field: field)) {
                _ = try await client.submit(draft, userToken: "token-123")
            }
            #expect(counter.callCount == 0, "An invalid draft must never consume a Turnstile token")
        }
        #expect(capture.value == nil, "An invalid draft must be rejected before any request is sent")
    }

    @Test("submit accepts boundary-length drafts, trims padded fields, and consumes exactly one token")
    func submitAcceptsBoundaryDrafts() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (
                makeHTTPResponse(),
                try encodeJSON(["submissionId": "s-1", "forwardedToGithub": true])
            )
        }
        let (client, counter) = Self.makeCountingClient()

        // Exactly at every floor — the smallest drafts the server accepts.
        let atMinimum = FeedbackDraft(
            title: String(repeating: "t", count: IntakeTextLimits.minTitleLength),
            description: String(repeating: "d", count: IntakeTextLimits.minDescriptionLength),
            platform: .ios
        )
        let result = try await client.submit(atMinimum, userToken: "token-123")
        #expect(result.submissionId == "s-1")
        #expect(counter.callCount == 1, "A valid draft consumes exactly one Turnstile token")

        // Padded-but-valid drafts still dispatch and are trimmed on the wire.
        let padded = FeedbackDraft(title: "  abc  ", description: " abcde ", platform: .ios)
        _ = try await client.submit(padded, userToken: "token-123")
        #expect(counter.callCount == 2)

        let request = try #require(capture.value)
        let sentBody = try #require(bodyData(from: request))
        let json = try #require(parseJSONDict(sentBody))
        #expect(json["title"] as? String == "abc")
        #expect(json["description"] as? String == "abcde")
    }

    // MARK: - UI form gates agree with the client (shared constants)

    @Test("the feedback form gate accepts exactly the drafts the client accepts")
    func feedbackFormGateMatchesClientBounds() {
        let stateMachine = FeedbackAttachmentStateMachine()
        #expect(!stateMachine.canSubmit(draft: FeedbackDraft(title: "ab", description: "Valid description", platform: .ios)))
        #expect(!stateMachine.canSubmit(draft: FeedbackDraft(title: "Valid title", description: "abcd", platform: .ios)))
        #expect(stateMachine.canSubmit(draft: FeedbackDraft(
            title: String(repeating: "t", count: IntakeTextLimits.minTitleLength),
            description: String(repeating: "d", count: IntakeTextLimits.minDescriptionLength),
            platform: .ios
        )))
    }
}
