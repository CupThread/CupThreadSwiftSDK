import Foundation
import Testing
@testable import CupThreadFeedback

/// Schema-parity guard for the bounded `FeedbackSubmissionInput` fields on
/// `POST /api/v1/feedback`: the cap
/// ``FeedbackSubmissionLimits/maxAttachmentCount`` enforces locally must
/// equal the `maxItems` the live OpenAPI document publishes on
/// `FeedbackSubmissionInput.uploadIds` (and on the legacy `attachments`
/// array the same typed error covers), and the version-string clamp
/// ``IntakeTextLimits/maxVersionLength`` must equal the live `maxLength` on
/// `appVersion`/`buildNumber` (issue #618). When the server's contract
/// drifts, this suite fails a test instead of a host's production
/// submission. The sibling bounds are guarded the same way by
/// ``UploadSessionSchemaParityTests`` and ``EndUserAttributesSchemaParityTests``.
@Suite("FeedbackSubmissionSchemaParity", .serialized)
struct FeedbackSubmissionSchemaParityTests {
    /// The live OpenAPI document the SDK contract is published as.
    static let specURL = URL(string: "https://api.cupthread.com/api/v1/openapi.json")!

    private struct OpenAPIProperty: Decodable {
        let type: String?
        let maxItems: Int?
        let maxLength: Int?
    }

    private struct OpenAPISchemaObject: Decodable {
        let properties: [String: OpenAPIProperty]?
    }

    private struct OpenAPISpec: Decodable {
        struct Components: Decodable {
            let schemas: [String: OpenAPISchemaObject]
        }

        let components: Components
    }

    private static func fetchLiveSpecResponse() async throws -> (data: Data, status: Int) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: specURL)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Records an inconclusive parity check (no network, or a temporary
    /// api.cupthread.com outage) as a known issue instead of failing the
    /// run: neither situation is schema drift, the suite stays completable
    /// offline, CI never fails on an outage, and the drift tripwire stays
    /// armed for every run that can reach the API (CI, networked dev).
    private static func recordInconclusiveParity(_ reason: String) {
        withKnownIssue {
            Issue.record("""
                Live OpenAPI document \(reason) at \(specURL); \
                feedback-submission attachment-bound parity was not verified this run
                """)
        }
    }

    /// Fetches and decodes the live OpenAPI document, treating transport
    /// failures and HTTP 5xx as inconclusive (recorded, not failed).
    /// Everything else — a 4xx status (the document moved or was removed),
    /// a non-schema body on a success status, or a schema-shape violation —
    /// throws, because those are contract drift, not outages.
    private static func fetchLiveSpecRecordingInconclusive() async throws -> OpenAPISpec? {
        let payload: (data: Data, status: Int)
        do {
            payload = try await Self.fetchLiveSpecResponse()
        } catch let error as URLError where !error.isSdkCancellation {
            recordInconclusiveParity("unreachable (\(error))")
            return nil
        }
        guard !(500...599).contains(payload.status) else {
            recordInconclusiveParity("answered HTTP \(payload.status)")
            return nil
        }
        return try JSONDecoder().decode(OpenAPISpec.self, from: payload.data)
    }

    /// The live `FeedbackSubmissionInput` properties, or `nil` when the
    /// document could not be fetched this run.
    private static func liveSubmissionInputProperties() async throws -> [String: OpenAPIProperty]? {
        guard let spec = try await fetchLiveSpecRecordingInconclusive() else { return nil }
        return try #require(
            spec.components.schemas["FeedbackSubmissionInput"]?.properties,
            "The live OpenAPI document no longer carries FeedbackSubmissionInput — update this suite"
        )
    }

    /// ``FeedbackSubmissionLimits/maxAttachmentCount`` equals the live
    /// `FeedbackSubmissionInput.uploadIds.maxItems`, and the property stays
    /// an array — a type drift changes what the SDK may encode.
    @Test func sdkAttachmentCountCapMatchesLiveUploadIdsSchema() async throws {
        guard let input = try await Self.liveSubmissionInputProperties() else { return }
        let uploadIds = try #require(
            input["uploadIds"],
            "The live schema no longer carries FeedbackSubmissionInput.uploadIds"
        )

        #expect(uploadIds.type == "array")
        #expect(
            uploadIds.maxItems == FeedbackSubmissionLimits.maxAttachmentCount,
            """
            Attachment-count cap drift: the SDK enforces at most \(FeedbackSubmissionLimits.maxAttachmentCount) \
            uploadIds but the live schema publishes maxItems \(uploadIds.maxItems.map(String.init(describing:)) ?? "none") \
            (issue #613).
            """
        )
    }

    /// The legacy `attachments` array shares the cap: the residual-400 mapping
    /// treats a field error on either array as the same typed error, which
    /// only holds while both bounds agree.
    @Test func legacyAttachmentsArrayShareTheSameLiveCap() async throws {
        guard let input = try await Self.liveSubmissionInputProperties() else { return }
        let attachments = try #require(
            input["attachments"],
            "The live schema no longer carries FeedbackSubmissionInput.attachments"
        )

        #expect(attachments.type == "array")
        #expect(
            attachments.maxItems == FeedbackSubmissionLimits.maxAttachmentCount,
            """
            Legacy attachments cap drift: the SDK maps attachments field errors to the \
            \(FeedbackSubmissionLimits.maxAttachmentCount)-item typed error but the live schema publishes \
            maxItems \(attachments.maxItems.map(String.init(describing:)) ?? "none") (issue #613).
            """
        )
    }

    /// ``IntakeTextLimits/maxVersionLength`` equals the live
    /// `FeedbackSubmissionInput.appVersion.maxLength` and
    /// `.buildNumber.maxLength` (issue #618): the clamp cuts the wire value
    /// at the bound the server actually enforces, so drift here means the
    /// SDK either still sends a doomed submission (SDK bound too high) or
    /// truncates harder than the server requires (SDK bound too low).
    @Test func sdkVersionLengthCapMatchesLiveSchema() async throws {
        guard let input = try await Self.liveSubmissionInputProperties() else { return }
        for field in ["appVersion", "buildNumber"] {
            let property = try #require(
                input[field],
                "The live schema no longer carries FeedbackSubmissionInput.\(field)"
            )

            #expect(property.type == "string")
            #expect(
                property.maxLength == IntakeTextLimits.maxVersionLength,
                """
                Version-string cap drift: the SDK clamps \(field) to \
                \(IntakeTextLimits.maxVersionLength) code points but the live schema publishes \
                maxLength \(property.maxLength.map(String.init(describing:)) ?? "none") (issue #618).
                """
            )
        }
    }
}
