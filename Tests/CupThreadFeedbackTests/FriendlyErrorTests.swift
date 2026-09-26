import Foundation
import Testing
@testable import CupThreadFeedback

/// Issue #30: raw server response bodies must never reach end-user UI copy,
/// while staying retrievable from the error value for diagnostics.
@Suite("FriendlyError")
struct FriendlyErrorTests {
    private let htmlBody = "<html><body><h1>502 Bad Gateway</h1><p>nginx/1.24.0</p></body></html>"

    // MARK: - No raw markup in UI copy (requirement 1)

    @Test func unexpectedStatusHTMLBodyNeverReachesErrorDescription() throws {
        let error = FeedbackClientError.unexpectedStatus(code: 502, message: htmlBody, requestId: nil)
        let desc = try #require(error.errorDescription)
        #expect(desc == CupThreadStrings.tr("cupthread.error.http_server_busy"))
        #expect(!desc.contains("<"))
        #expect(!desc.lowercased().contains("html"))
        #expect(!desc.contains("nginx"))
    }

    @Test func userProfileNotFoundHidesServerMessage() throws {
        let error = FeedbackClientError.userProfileNotFound(message: htmlBody)
        let desc = try #require(error.errorDescription)
        #expect(desc == "This user profile is no longer available.")
        #expect(!desc.contains("<"))
        #expect(!desc.lowercased().contains("html"))
    }

    @Test func scanRejectedHTMLBodyNeverReachesErrorDescriptionOrFriendlyError() throws {
        let error = FeedbackClientError.scanRejected(message: htmlBody, requestId: nil)
        let desc = try #require(error.errorDescription)
        let expected = "The referenced attachment could not be uploaded due to content inspection rejection."
        #expect(desc == expected)
        #expect(!desc.contains("<"))
        #expect(!desc.lowercased().contains("html"))
        #expect(!desc.contains("nginx"))
        #expect(FriendlyError.message(for: error) == expected)
        #expect(error.scanDetail == htmlBody)
    }

    @Test func scanRejectedWithRequestIdPreservesSuffixWithoutServerMessage() throws {
        let error = FeedbackClientError.scanRejected(
            message: "scanner rule 42: forbidden executable inside archive",
            requestId: "req-scan-99"
        )
        let desc = try #require(error.errorDescription)
        let expected = "The referenced attachment could not be uploaded due to content inspection rejection. (request id: req-scan-99)"
        #expect(desc == expected)
        #expect(!desc.contains("rule 42"))
        #expect(!desc.contains("forbidden executable"))
        #expect(FriendlyError.message(for: error) == expected)
        #expect(error.scanDetail == "scanner rule 42: forbidden executable inside archive")
        #expect(error.requestId == "req-scan-99")
    }

    @Test func friendlyErrorRoutesClientErrorsThroughErrorDescription() {
        let error = FeedbackClientError.unexpectedStatus(code: 502, message: htmlBody, requestId: nil)
        #expect(FriendlyError.message(for: error) == error.errorDescription)
    }

    // MARK: - Length clamp (requirement 2)

    @Test func hugeBodyNeverInflatesDisplayCopy() throws {
        let hugeBody = String(repeating: "x", count: 5_000)
        let error = FeedbackClientError.unexpectedStatus(code: 500, message: hugeBody, requestId: nil)
        let desc = try #require(error.errorDescription)
        #expect(desc.count <= 200, "Display copy must stay short, got \(desc.count) characters")
        #expect(!desc.contains(hugeBody))
    }

    // MARK: - Status mapping (requirement 3)

    @Test func mappedStatusesProduceDistinctLocalizedStrings() throws {
        let notFound = try #require(
            FeedbackClientError.unexpectedStatus(code: 404, message: "", requestId: nil).errorDescription
        )
        let rateLimited = try #require(
            FeedbackClientError.unexpectedStatus(code: 429, message: "", requestId: nil).errorDescription
        )
        let serverError = try #require(
            FeedbackClientError.unexpectedStatus(code: 500, message: "", requestId: nil).errorDescription
        )
        #expect(notFound == CupThreadStrings.tr("cupthread.error.http_not_found"))
        #expect(rateLimited == CupThreadStrings.tr("cupthread.error.http_rate_limited"))
        #expect(serverError == CupThreadStrings.tr("cupthread.error.http_server_busy"))
        #expect(notFound != rateLimited)
        #expect(notFound != serverError)
        #expect(rateLimited != serverError)
    }

    @Test func unauthorizedStatusMapsToSignInCopy() throws {
        let error = FeedbackClientError.unexpectedStatus(code: 401, message: "denied", requestId: nil)
        let desc = try #require(error.errorDescription)
        #expect(desc == CupThreadStrings.tr("cupthread.error.http_unauthorized"))
    }

    @Test func unmappedStatusFallsBackToGenericCopy() throws {
        let error = FeedbackClientError.unexpectedStatus(code: 418, message: "teapot", requestId: nil)
        let desc = try #require(error.errorDescription)
        #expect(desc == CupThreadStrings.tr("cupthread.error.request_failed"))
    }

    @Test func requestIdSuffixSurvivesStatusMapping() throws {
        let error = FeedbackClientError.unexpectedStatus(code: 503, message: "oops", requestId: "req-30")
        let desc = try #require(error.errorDescription)
        #expect(desc == CupThreadStrings.tr("cupthread.error.http_server_busy") + " (request id: req-30)")
    }

    // MARK: - Connectivity mapping (requirement 3, mapping layer)

    @Test func offlineURLErrorMapsToOfflineCopy() {
        let message = FriendlyError.message(for: URLError(.notConnectedToInternet))
        #expect(message == CupThreadStrings.tr("cupthread.error.offline"))
    }

    @Test func timedOutURLErrorMapsToTimeoutCopy() {
        let message = FriendlyError.message(for: URLError(.timedOut))
        #expect(message == CupThreadStrings.tr("cupthread.error.timed_out"))
    }

    @Test func connectivityURLErrorsMapToOfflineCopy() {
        for code in [URLError.networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed] {
            #expect(
                FriendlyError.message(for: URLError(code)) == CupThreadStrings.tr("cupthread.error.offline"),
                "URLError code \(code.rawValue) should map to the offline copy"
            )
        }
    }

    @Test func otherURLErrorsFallBackToSystemCopy() {
        let urlError = URLError(.badURL)
        #expect(FriendlyError.message(for: urlError) == urlError.localizedDescription)
    }

    @Test func unknownErrorTypesFallBackToSystemCopy() {
        struct OpaqueError: Error {}
        let error = OpaqueError()
        #expect(FriendlyError.message(for: error) == error.localizedDescription)
    }

    // MARK: - End to end through the shared response validator

    @Test func validateResponseCapturesHTMLBodyButDisplayStaysFriendly() throws {
        let client = FeedbackClient(
            configuration: FeedbackClientConfiguration(
                baseURL: URL(string: "https://api.cupthread.com")!,
                appKey: "app_test"
            )
        )
        let response = try #require(
            HTTPURLResponse(url: client.configuration.baseURL, statusCode: 502, httpVersion: nil, headerFields: nil)
        )
        do {
            try client.validateResponse(response, data: Data(htmlBody.utf8), accepted: [200])
            Issue.record("Expected validateResponse to throw for HTTP 502")
        } catch let error as FeedbackClientError {
            #expect(error.responseBody == htmlBody)
            #expect(error.errorDescription == CupThreadStrings.tr("cupthread.error.http_server_busy"))
        }
    }

    // MARK: - Diagnostics preserved (requirement 4)

    @Test func responseBodyReturnsFullRawBodyForUnexpectedStatus() {
        let error = FeedbackClientError.unexpectedStatus(code: 502, message: htmlBody, requestId: nil)
        #expect(error.responseBody == htmlBody)
    }

    @Test func responseBodyReturnsFullRawBodyForUserProfileNotFound() {
        let error = FeedbackClientError.userProfileNotFound(message: htmlBody)
        #expect(error.responseBody == htmlBody)
    }

    @Test func responseBodyIsNilForTypedErrorsWithoutBodies() {
        #expect(FeedbackClientError.invalidResponse.responseBody == nil)
        #expect(FeedbackClientError.unreadableUploadResponse.responseBody == nil)
        #expect(FeedbackClientError.authenticationRequired.responseBody == nil)
        #expect(FeedbackClientError.forbidden(message: "<html>nope</html>", requestId: "r").responseBody == nil)
        #expect(FeedbackClientError.scanRejected(message: "reason", requestId: nil).responseBody == nil)
        #expect(FeedbackClientError.rateLimited(message: "slow down", requestId: nil).responseBody == nil)
        #expect(FeedbackClientError.unsupportedMediaType(message: nil, requestId: nil).responseBody == nil)
        #expect(FeedbackClientError.payloadTooLarge(message: nil, requestId: nil).responseBody == nil)
        #expect(FeedbackClientError.uploaderIdentityRequired(message: nil, requestId: nil).responseBody == nil)
        #expect(FeedbackClientError.uploaderMismatch(message: nil, requestId: nil).responseBody == nil)
        #expect(FeedbackClientError.submissionQuotaExceeded(message: nil, requestId: nil).responseBody == nil)
        #expect(FeedbackClientError.subscriptionInactive(message: nil, requestId: nil).responseBody == nil)
    }

    @Test func scanDetailPreservesRawRejectionMessage() {
        let error = FeedbackClientError.scanRejected(message: htmlBody, requestId: "req-1")
        #expect(error.scanDetail == htmlBody)
        #expect(FeedbackClientError.invalidResponse.scanDetail == nil)
        #expect(FeedbackClientError.forbidden(message: "nope", requestId: nil).scanDetail == nil)
    }

    // MARK: - Composer and Subscribe intake surfaces (issue #160)

    @Test func composerAndSubscribeErrorMappingContracts() {
        // URLError connectivity mapping: offline and timeout
        let offlineURLError = URLError(.notConnectedToInternet)
        #expect(FriendlyError.message(for: offlineURLError) == CupThreadStrings.tr("cupthread.error.offline"))
        #expect(FriendlyError.message(for: offlineURLError) != offlineURLError.localizedDescription)

        let timedOutURLError = URLError(.timedOut)
        #expect(FriendlyError.message(for: timedOutURLError) == CupThreadStrings.tr("cupthread.error.timed_out"))
        #expect(FriendlyError.message(for: timedOutURLError) != timedOutURLError.localizedDescription)

        // FeedbackClientError mapping: status 502 / server errors
        let serverError = FeedbackClientError.unexpectedStatus(
            code: 502,
            message: "<html>Bad Gateway</html>",
            requestId: nil
        )
        #expect(FriendlyError.message(for: serverError) == CupThreadStrings.tr("cupthread.error.http_server_busy"))
        #expect(!FriendlyError.message(for: serverError).contains("<html>"))
    }

    @Test func userFacingSurfacesDoNotReadLocalizedDescriptionDirectly() throws {
        var directory = URL(fileURLWithPath: #filePath)
        var sourceDir: URL?
        for _ in 0..<6 {
            directory.deleteLastPathComponent()
            let candidate = directory
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("CupThreadFeedback", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                sourceDir = candidate
                break
            }
        }
        let sourcesURL = try #require(sourceDir, "Could not locate Sources/CupThreadFeedback")
        let files = try #require(
            FileManager.default
                .enumerator(at: sourcesURL, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "FriendlyError.swift" },
            "Failed to enumerate Swift sources under \(sourcesURL)"
        )

        var violations: [String] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let source = try String(contentsOf: file, encoding: .utf8)
            let lines = source.components(separatedBy: .newlines)
            for (offset, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                    continue
                }
                if line.contains(".localizedDescription") {
                    violations.append("\(file.lastPathComponent):\(offset + 1): \(trimmed)")
                }
            }
        }

        #expect(
            violations.isEmpty,
            "SDK surfaces must route errors through FriendlyError.message(for:) instead of reading .localizedDescription directly (issue #30, #160). Violations:\n\(violations.joined(separator: "\n"))"
        )
    }
}
