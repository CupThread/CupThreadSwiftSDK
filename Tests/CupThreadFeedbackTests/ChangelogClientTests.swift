import Foundation
import Testing
@testable import CupThreadFeedback

// All network tests share the static MockURLProtocol handler, so they run serialized.
// This suite uses its own base host so it can run in parallel with the other suites.
@Suite("ChangelogClient", .serialized)
struct ChangelogClientTests {
    static let apiHost = "changelog.example.com"

    static func makeChangelogClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(apiHost)")!)
    }

    // MARK: - Fetch

    @Test func fetchChangelogHitsPublicChangelogEndpoint() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["entries": []]))
        }

        _ = try await Self.makeChangelogClient().fetchChangelog()

        let request = try #require(capture.value)
        #expect(request.url?.path == "/api/v1/public/apps/app_testkey123456/changelog")
        #expect(request.httpMethod == "GET")
    }

    @Test func fetchChangelogSortsEntriesNewestFirst() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            let entries = [
                makeEntryJSON(id: "e1", title: "Launch", publishedAt: "2026-01-10T00:00:00.000Z"),
                makeEntryJSON(id: "e3", title: "Older", publishedAt: "2025-12-01T00:00:00.000Z"),
                makeEntryJSON(id: "e2", title: "Widgets", publishedAt: "2026-03-05T00:00:00.000Z")
            ]
            return (makeHTTPResponse(), try encodeJSON(["entries": entries]))
        }

        let entries = try await Self.makeChangelogClient().fetchChangelog()

        #expect(entries.map(\.id) == ["e2", "e1", "e3"])
    }

    @Test func fetchChangelogDecodesAllFields() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            let entries = [
                makeEntryJSON(
                    id: "e1",
                    title: "Widgets & Dark Mode",
                    publishedAt: "2026-02-20T12:00:00Z",
                    versionLabel: nil,
                    linkedRequests: []
                )
            ]
            return (makeHTTPResponse(), try encodeJSON(["entries": entries]))
        }

        let entries = try await Self.makeChangelogClient().fetchChangelog()

        let entry = try #require(entries.first)
        #expect(entry.id == "e1")
        #expect(entry.title == "Widgets & Dark Mode")
        #expect(entry.body == "Improvements and fixes.")
        #expect(entry.versionLabel == nil)
        #expect(entry.publishedAt == "2026-02-20T12:00:00Z")
        #expect(entry.linkedRequests.isEmpty)
    }

    @Test func fetchChangelogMaps401ToFriendlyError() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 401), try encodeJSON(["code": "authentication_required"]))
        }

        do {
            _ = try await Self.makeChangelogClient().fetchChangelog()
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            guard case .authenticationRequired = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
            #expect(error.errorDescription != nil)
        }
    }

    @Test func fetchChangelogThrowsUnexpectedStatusOnUnknownAppKey() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 404), try encodeJSON(["error": "App not found"]))
        }

        do {
            _ = try await Self.makeChangelogClient().fetchChangelog()
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            if case .unexpectedStatus(let code, _) = error {
                #expect(code == 404)
            } else {
                Issue.record("Unexpected error type: \(error)")
            }
        }
    }

    // MARK: - Subscribe

    @Test func subscribeSendsPostWithTokenAndEmailBody() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(status: 201), try encodeJSON(["subscribed": true, "alreadySubscribed": false]))
        }

        let token = UUID().uuidString
        let result = try await Self.makeChangelogClient().subscribeToChangelog(
            email: "  user@example.com  ",
            userToken: token
        )

        let request = try #require(capture.value)
        #expect(request.url?.path == "/api/v1/public/apps/app_testkey123456/changelog/subscribe")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-User-Token") == token)

        let rawData = try #require(bodyData(from: request))
        let json = try #require(parseJSONDict(rawData))
        #expect(json["email"] as? String == "user@example.com")

        #expect(result.subscribed == true)
        #expect(result.alreadySubscribed == false)
    }

    @Test func subscribeDecodesAlreadySubscribed() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 201), try encodeJSON(["subscribed": false, "alreadySubscribed": true]))
        }

        let result = try await Self.makeChangelogClient().subscribeToChangelog(
            email: "user@example.com",
            userToken: UUID().uuidString
        )

        #expect(result.subscribed == false)
        #expect(result.alreadySubscribed == true)
    }

    @Test func subscribeThrowsOnValidationError() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 400), try encodeJSON(["error": "Invalid email"]))
        }

        do {
            _ = try await Self.makeChangelogClient().subscribeToChangelog(
                email: "not-an-email",
                userToken: UUID().uuidString
            )
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            if case .unexpectedStatus(let code, _) = error {
                #expect(code == 400)
            } else {
                Issue.record("Unexpected error type: \(error)")
            }
        }
    }

    // MARK: - Unsubscribe

    @Test func unsubscribeSendsPostAndDecodesResult() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["unsubscribed": true]))
        }

        let result = try await Self.makeChangelogClient().unsubscribeFromChangelog(email: " user@example.com ")

        let request = try #require(capture.value)
        #expect(request.url?.path == "/api/v1/public/apps/app_testkey123456/changelog/unsubscribe")
        #expect(request.httpMethod == "POST")

        let rawData = try #require(bodyData(from: request))
        let json = try #require(parseJSONDict(rawData))
        #expect(json["email"] as? String == "user@example.com")

        #expect(result.unsubscribed == true)
    }

    // MARK: - User attributes

    @Test func updateUserAttributesSendsPutWithTokenAndPayload() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["ok": true, "updatedAt": "2026-03-05T10:00:00.000Z"]))
        }

        let token = UUID().uuidString
        let result = try await Self.makeChangelogClient().updateUserAttributes(
            isPaying: true,
            plan: "pro",
            mrr: 12.5,
            currency: "EUR",
            userToken: token
        )

        let request = try #require(capture.value)
        #expect(request.url?.path == "/api/v1/public/apps/app_testkey123456/user")
        #expect(request.httpMethod == "PUT")
        #expect(request.value(forHTTPHeaderField: "X-User-Token") == token)

        let rawData = try #require(bodyData(from: request))
        let json = try #require(parseJSONDict(rawData))
        #expect(json["isPaying"] as? Bool == true)
        #expect(json["plan"] as? String == "pro")
        #expect(json["mrr"] as? Double == 12.5)
        #expect(json["currency"] as? String == "EUR")

        #expect(result.ok == true)
        #expect(result.updatedAt == "2026-03-05T10:00:00.000Z")
    }

    @Test func updateUserAttributesOmitsNilFields() async throws {
        let capture = CaptureBox<Data>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = bodyData(from: request)
            return (makeHTTPResponse(), try encodeJSON(["ok": true, "updatedAt": "2026-03-05T10:00:00.000Z"]))
        }

        _ = try await Self.makeChangelogClient().updateUserAttributes(
            isPaying: false,
            userToken: UUID().uuidString
        )

        let rawData = try #require(capture.value)
        let json = try #require(parseJSONDict(rawData))
        #expect(json["isPaying"] as? Bool == false)
        // nil optionals are skipped by JSONEncoder → keys absent from the payload
        #expect(json["plan"] == nil)
        #expect(json["mrr"] == nil)
        #expect(json["currency"] == nil)
    }

    // MARK: - ChangelogEntry decoding (server shape)

    @Test func changelogEntryDecodesServerRecord() throws {
        let json = """
        {
            "id": "cl-1",
            "title": "Widgets & Dark Mode",
            "body": "Two of the most requested features have shipped.",
            "versionLabel": "2.4.0",
            "publishedAt": "2026-02-20T12:00:00Z",
            "linkedRequests": [
                { "id": "fr-1", "title": "Dark mode" },
                { "id": "fr-2", "title": "Home screen widgets" }
            ]
        }
        """.data(using: .utf8)!

        let entry = try JSONDecoder().decode(ChangelogEntry.self, from: json)

        #expect(entry.title == "Widgets & Dark Mode")
        #expect(entry.body == "Two of the most requested features have shipped.")
        #expect(entry.versionLabel == "2.4.0")
        #expect(entry.linkedRequests.map(\.title) == ["Dark mode", "Home screen widgets"])
        #expect(entry.linkedRequests.first?.id == "fr-1")
        let expected = try Date("2026-02-20T12:00:00Z", strategy: .iso8601)
        #expect(entry.publishedAtDate == expected)
    }

    @Test func changelogEntryParsesFractionalSecondDates() throws {
        let json = """
        {
            "id": "cl-2",
            "title": "Performance",
            "body": "Faster launches.",
            "versionLabel": null,
            "publishedAt": "2026-03-01T08:30:00.123Z",
            "linkedRequests": []
        }
        """.data(using: .utf8)!

        let entry = try JSONDecoder().decode(ChangelogEntry.self, from: json)

        #expect(entry.versionLabel == nil)
        let expected = try Date(
            "2026-03-01T08:30:00.123Z",
            strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        )
        #expect(entry.publishedAtDate != nil)
        #expect(entry.publishedAtDate == expected)
    }
}

// MARK: - JSON fixtures

private func makeEntryJSON(
    id: String,
    title: String,
    publishedAt: String,
    versionLabel: String? = "2.1",
    linkedRequests: [[String: String]] = [["id": "fr-1", "title": "Dark mode"]]
) -> [String: Any] {
    [
        "id": id,
        "title": title,
        "body": "Improvements and fixes.",
        "versionLabel": versionLabel ?? NSNull(),
        "publishedAt": publishedAt,
        "linkedRequests": linkedRequests
    ]
}
