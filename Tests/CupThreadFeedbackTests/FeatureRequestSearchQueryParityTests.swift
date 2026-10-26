import Foundation
import Testing
@testable import CupThreadFeedback

/// Schema-parity guard for the search term on
/// `GET /api/v1/feature-requests` (issue #610): the `q` cap
/// ``FeatureRequestSearchLimits/maxQueryLength`` enforces locally must equal
/// the `maxLength` the live OpenAPI document publishes on the endpoint's
/// inline `q` parameter. When the server's contract drifts, this suite fails
/// a test instead of a host's production search. The payload bounds are
/// guarded the same way by ``UploadSessionSchemaParityTests`` and
/// ``EndUserAttributesSchemaParityTests``.
@Suite("FeatureRequestSearchQueryParity", .serialized)
struct FeatureRequestSearchQueryParityTests {
    /// The live OpenAPI document the SDK contract is published as.
    static let specURL = URL(string: "https://api.cupthread.com/api/v1/openapi.json")!

    private struct OpenAPIQuerySchema: Decodable {
        let type: String?
        let maxLength: Int?
    }

    private struct OpenAPIParameter: Decodable {
        let name: String?
        let schema: OpenAPIQuerySchema?
    }

    private struct OpenAPIOperation: Decodable {
        let parameters: [OpenAPIParameter]?
    }

    private struct OpenAPIPathItem: Decodable {
        let get: OpenAPIOperation?
    }

    private struct OpenAPISpec: Decodable {
        let paths: [String: OpenAPIPathItem]
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
                feature-request search `q` bound parity was not verified this run
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

    /// ``FeatureRequestSearchLimits/maxQueryLength`` equals the live
    /// `paths["/api/v1/feature-requests"].get` `q` parameter's
    /// `schema.maxLength` (#610).
    @Test func sdkMaxQueryLengthMatchesLiveSchema() async throws {
        guard let spec = try await Self.fetchLiveSpecRecordingInconclusive() else { return }
        let operation = try #require(
            spec.paths["/api/v1/feature-requests"]?.get,
            "The live OpenAPI document no longer carries GET /api/v1/feature-requests — update this suite"
        )
        let parameter = try #require(
            operation.parameters?.first { $0.name == "q" },
            "The live operation no longer carries a q parameter — update this suite"
        )
        let schema = try #require(
            parameter.schema,
            "The live q parameter no longer publishes a schema"
        )

        #expect(schema.type == "string")
        #expect(
            schema.maxLength == FeatureRequestSearchLimits.maxQueryLength,
            """
            Search-term cap drift: the SDK truncates `q` to \
            \(FeatureRequestSearchLimits.maxQueryLength) code points but the live schema \
            publishes maxLength \(schema.maxLength.map(String.init(describing:)) ?? "none") \
            (issue #610).
            """
        )
    }
}
