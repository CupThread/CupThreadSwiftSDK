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
}
