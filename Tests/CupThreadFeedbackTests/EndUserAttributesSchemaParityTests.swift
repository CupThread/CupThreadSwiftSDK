import Foundation
import Testing
@testable import CupThreadFeedback

/// Schema-parity guard for `PUT /api/v1/public/apps/{appKey}/user`
/// (issue #573): the SDK's clearable-attribute policy must match the live
/// `EndUserAttributesInput` schema field by field — an explicit JSON `null`
/// is legal for `plan` and `mrr` (`nullable: true`) and illegal for
/// `isPaying` and `currency`. When the server's nullability drifts, this
/// suite fails a test instead of a host's production request. The same
/// drift in the sibling `PublicAppConfig` schema is guarded by
/// ``PublicAppConfigSchemaParityTests``.
@Suite("EndUserAttributesSchemaParity", .serialized)
struct EndUserAttributesSchemaParityTests {
    static let apiHost = "user-attributes-parity.example.com"
    /// The live OpenAPI document the SDK contract is published as.
    static let specURL = URL(string: "https://api.cupthread.com/api/v1/openapi.json")!

    private struct OpenAPIProperty: Decodable {
        let type: String?
        let nullable: Bool?
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
                EndUserAttributesInput nullability parity was not verified this run
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

    /// Field-by-field: the attributes the SDK allows clearing with `.null`
    /// (`plan`, `mrr` — accepted and signed normally) are exactly the ones
    /// the live schema marks `nullable: true`, and the attributes it rejects
    /// (`isPaying`, `currency` — `.attributeNotClearable` before any network
    /// activity) are exactly the ones it does not.
    @Test func sdkClearablePolicyMatchesLiveSchemaNullability() async throws {
        guard let spec = try await Self.fetchLiveSpecRecordingInconclusive() else { return }
        let input = try #require(
            spec.components.schemas["EndUserAttributesInput"]?.properties,
            "The live OpenAPI document no longer carries EndUserAttributesInput — update this suite"
        )

        let requests = CaptureBox<[URLRequest]>()
        requests.value = []
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            requests.value?.append(request)
            return (makeHTTPResponse(), try encodeJSON(["ok": true, "updatedAt": "2026-10-25T00:00:00.000Z"]))
        }
        let client = makeClient(
            baseURL: URL(string: "https://\(Self.apiHost)")!,
            appKey: "app_testkey123456",
            signingSecret: "sec_parity_secret"
        )

        // SDK verdict per field: can this attribute be cleared with `.null`?
        // Sequential — the mock session and capture box are shared state.
        let token = "user-uuid-schema-parity"
        var verdicts: [String: Bool] = [:]

        _ = try await client.updateUserAttributes(plan: .null, userToken: token)
        verdicts["plan"] = true
        _ = try await client.updateUserAttributes(mrr: .null, userToken: token)
        verdicts["mrr"] = true

        await #expect(throws: FeedbackClientError.attributeNotClearable(attribute: "isPaying")) {
            try await client.updateUserAttributes(isPaying: .null, userToken: token)
        }
        verdicts["isPaying"] = false
        await #expect(throws: FeedbackClientError.attributeNotClearable(attribute: "currency")) {
            try await client.updateUserAttributes(currency: .null, userToken: token)
        }
        verdicts["currency"] = false

        // The wire only ever saw the two clears the SDK accepts.
        #expect((requests.value ?? []).count == 2)

        // Parity, field by field: SDK clearable ⇔ live schema nullable.
        for (name, sdkClearable) in verdicts.sorted(by: { $0.key < $1.key }) {
            let property = try #require(
                input[name],
                "The live OpenAPI document no longer carries EndUserAttributesInput.\(name)"
            )
            let schemaNullable = property.nullable == true
            #expect(
                sdkClearable == schemaNullable,
                """
                Nullability drift on \(name): the SDK \(sdkClearable ? "accepts" : "rejects") \
                `.null` but the live schema marks it \(property.nullable == true ? "nullable" : "non-nullable") \
                (type: \(property.type ?? "?")). Reconcile the SDK's clearable-attribute \
                policy with the server contract (issue #573).
                """
            )
        }

        // The non-nullability itself: `isPaying` stays boolean and `currency`
        // stays string — a type drift changes what the SDK may encode.
        #expect(input["isPaying"]?.type == "boolean")
        #expect(input["currency"]?.type == "string")
        #expect(input["plan"]?.type == "string")
        #expect(input["mrr"]?.type == "number")
    }
}
