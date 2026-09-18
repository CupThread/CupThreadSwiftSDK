import Foundation

/// Maps any thrown error to a short, localized, end-user-safe message.
///
/// Server-controlled text — raw HTML/XML gateway pages, stack traces,
/// unbounded response bodies — never reaches the UI through this layer:
/// typed ``FeedbackClientError`` values render their curated, localized
/// ``LocalizedError/errorDescription`` copy, connectivity failures map to
/// dedicated offline and timeout copy, and everything else falls back to
/// the system-localized description. SDK surfaces route failures through
/// ``message(for:)`` instead of reading `localizedDescription` directly.
enum FriendlyError {
    /// - Parameter error: The error a load or submission failed with.
    /// - Returns: User-safe display copy for the error.
    static func message(for error: Error) -> String {
        if let clientError = error as? FeedbackClientError, let description = clientError.errorDescription {
            return description
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return CupThreadStrings.tr("cupthread.error.timed_out")
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed:
                return CupThreadStrings.tr("cupthread.error.offline")
            default:
                break
            }
        }
        return error.localizedDescription
    }
}
