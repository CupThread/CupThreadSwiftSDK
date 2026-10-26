import Foundation
import Testing
@testable import CupThreadFeedback

/// Schema-parity guard for `POST /api/v1/uploads/sessions` (issue #611):
/// the payload bounds ``UploadSessionLimits`` enforces locally must equal
/// the bounds the live OpenAPI document publishes —
/// `CreateUploadSessionFileInput.sizeBytes.minimum` and
/// `CreateUploadSessionInput.files.minItems` / `maxItems`. When the server's
/// contract drifts, this suite fails a test instead of a host's production
/// upload. The sibling attribute bounds are guarded the same way by
/// ``EndUserAttributesSchemaParityTests``.
@Suite("UploadSessionSchemaParity", .serialized)
struct UploadSessionSchemaParityTests {
    /// The live OpenAPI document the SDK contract is published as.
    static let specURL = URL(string: "https://api.cupthread.com/api/v1/openapi.json")!

    private struct OpenAPIProperty: Decodable {
        let type: String?
        let minimum: Double?
        let minItems: Int?
        let maxItems: Int?
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
                upload-session payload-bound parity was not verified this run
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

    /// ``UploadSessionLimits/minFileSizeBytes`` equals the live
    /// `CreateUploadSessionFileInput.sizeBytes.minimum`, and the property
    /// stays an integer — a type drift changes what the SDK may encode.
    @Test func sdkFileSizeFloorMatchesLiveSchema() async throws {
        guard let spec = try await Self.fetchLiveSpecRecordingInconclusive() else { return }
        let input = try #require(
            spec.components.schemas["CreateUploadSessionFileInput"]?.properties,
            "The live OpenAPI document no longer carries CreateUploadSessionFileInput — update this suite"
        )
        let sizeBytes = try #require(
            input["sizeBytes"],
            "The live schema no longer carries CreateUploadSessionFileInput.sizeBytes"
        )

        #expect(sizeBytes.type == "integer")
        #expect(
            sizeBytes.minimum == Double(UploadSessionLimits.minFileSizeBytes),
            """
            File-size floor drift: the SDK enforces sizeBytes ≥ \(UploadSessionLimits.minFileSizeBytes) \
            but the live schema publishes minimum \(sizeBytes.minimum.map(String.init(describing:)) ?? "none") \
            (issue #611).
            """
        )
    }

    /// ``UploadSessionLimits/allowedFileCountRange`` equals the live
    /// `CreateUploadSessionInput.files.minItems...maxItems` (API-28). Until
    /// this test the range was asserted nowhere against the live document.
    @Test func sdkFileCountRangeMatchesLiveSchema() async throws {
        guard let spec = try await Self.fetchLiveSpecRecordingInconclusive() else { return }
        let input = try #require(
            spec.components.schemas["CreateUploadSessionInput"]?.properties,
            "The live OpenAPI document no longer carries CreateUploadSessionInput — update this suite"
        )
        let files = try #require(
            input["files"],
            "The live schema no longer carries CreateUploadSessionInput.files"
        )

        #expect(files.type == "array")
        #expect(
            files.minItems == UploadSessionLimits.allowedFileCountRange.lowerBound,
            """
            File-count floor drift: the SDK enforces at least \(UploadSessionLimits.allowedFileCountRange.lowerBound) \
            file but the live schema publishes minItems \(files.minItems.map(String.init(describing:)) ?? "none") \
            (API-28).
            """
        )
        #expect(
            files.maxItems == UploadSessionLimits.allowedFileCountRange.upperBound,
            """
            File-count cap drift: the SDK enforces at most \(UploadSessionLimits.allowedFileCountRange.upperBound) \
            files but the live schema publishes maxItems \(files.maxItems.map(String.init(describing:)) ?? "none") \
            (API-28).
            """
        )
    }
}
