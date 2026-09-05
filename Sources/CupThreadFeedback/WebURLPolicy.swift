import Foundation
import SwiftUI

// MARK: - URL Policy

/// Checks whether a URL is an allowed web URL:
/// - Must have `http` or `https` scheme.
/// - Must have a non-empty, non-whitespace host.
func isAllowedWebURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines),
          !host.isEmpty else {
        return false
    }
    return true
}

/// Normalizes and validates a website URL for user profiles:
/// - If already an allowed `http` or `https` URL with a valid host, returns it.
/// - If it contains a disallowed scheme (such as `tel:`, `javascript:`, `shortcuts://`, or custom schemes), returns `nil`.
/// - If it is scheme-less (e.g. `example.com`), prefixes `https://` and validates.
func normalizeWebsiteURL(_ string: String) -> URL? {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let candidate = URL(string: trimmed), let scheme = candidate.scheme {
        let lower = scheme.lowercased()
        if lower == "http" || lower == "https" {
            guard let host = candidate.host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else {
                return nil
            }
            return candidate
        } else {
            // Disallowed scheme
            return nil
        }
    }

    // Scheme-less, prefix https://
    guard let url = URL(string: "https://" + trimmed), isAllowedWebURL(url) else {
        return nil
    }
    return url
}

/// Sanitizes an `AttributedString` by removing the link attribute from any run
/// whose destination URL does not satisfy `isAllowedWebURL(_:)`.
func sanitizeMarkdownAttributedString(_ attributedString: AttributedString) -> AttributedString {
    var sanitized = attributedString
    for run in sanitized.runs {
        if let link = run.link, !isAllowedWebURL(link) {
            sanitized[run.range].link = nil
        }
    }
    return sanitized
}

// MARK: - View Modifiers

extension View {
    /// Defense-in-depth URL policy filtering: ensures only allowed `http` and `https`
    /// URLs are opened, suppressing disallowed schemes from untrusted content.
    func safeWebOpenURL() -> some View {
        environment(\.openURL, OpenURLAction { url in
            if isAllowedWebURL(url) {
                return .systemAction
            } else {
                return .handled
            }
        })
    }
}
