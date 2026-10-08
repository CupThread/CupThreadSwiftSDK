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

/// Checks whether a URL is an allowed secure remote image URL:
/// - Must have `https` scheme.
/// - Must have a non-empty, non-whitespace host.
func isAllowedSecureImageURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(),
          scheme == "https",
          let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines),
          !host.isEmpty else {
        return false
    }
    return true
}

/// Validates an untrusted remote image URL string (such as avatar or app icon URLs)
/// against HTTPS-only policy:
/// - Returns `nil` if the string is nil, empty, or cannot be parsed as a URL.
/// - Returns `nil` if the scheme is not `https` (e.g. `http:`, `file:`, `data:`, `javascript:`, custom schemes).
/// - Returns `nil` if the host is missing or whitespace.
/// - Returns the parsed `URL` only when permitted by `WebURLPolicy`.
func remoteImageURL(from string: String?) -> URL? {
    guard let string else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let candidate = URL(string: trimmed),
          isAllowedSecureImageURL(candidate) else {
        return nil
    }
    return candidate
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

/// Multi-tenant hosting suffixes that never imply a shared operator (curated,
/// zero-dependency subset of the Public Suffix List). Hosts that only share one
/// of these suffixes are different sites, so ``isAllowedDownloadHost(_:baseHost:)``
/// requires matching full registrable domains instead.
private let multiTenantHostSuffixes: Set<String> = [
    "amazonaws.com", "appspot.com", "azurewebsites.net", "azurestaticapps.net",
    "cloudfront.net", "firebaseapp.com", "fly.dev", "gitlab-pages.com", "gitlab.io",
    "github.io", "githubusercontent.com", "herokuapp.com", "netlify.app",
    "netlify.com", "onrender.com", "pages.dev", "r2.dev", "run.app", "surge.sh",
    "vercel.app", "web.app", "workers.dev"
]

/// Second-level labels the Public Suffix List reserves under country-code TLDs
/// (`co.uk`, `com.au`, `org.il`, …). Treating any `<label>.<tld>` pair whose
/// label is one of these as a public suffix also keeps unlisted ccSLDs
/// (e.g. `co.ke`) from collapsing unrelated hosts into a shared root.
private let registrySecondLevelLabels: Set<String> = [
    "ac", "co", "com", "edu", "go", "gov", "idv", "ne", "net", "or", "org"
]

/// Returns the registrable domain (public suffix plus one label) of `host`, or
/// `nil` when `host` is itself a bare public suffix and cannot establish
/// same-site trust.
private func registrableDomain(of host: String) -> String? {
    let labels = host.split(separator: ".")
    guard labels.count >= 2 else {
        return nil // A single label is a bare TLD (or an intranet host), never registrable.
    }
    let lastTwo = labels.suffix(2).joined(separator: ".")
    let endsWithPublicSuffix = multiTenantHostSuffixes.contains(lastTwo)
        || registrySecondLevelLabels.contains(String(labels[labels.count - 2]))
    guard endsWithPublicSuffix else {
        return lastTwo
    }
    // Under a public suffix the registrable domain needs one more label;
    // the bare suffix itself (`co.uk`, `github.io`) has none.
    return labels.count >= 3 ? labels.suffix(3).joined(separator: ".") : nil
}

/// Validates whether a candidate host is allowed for download URLs relative to a
/// base host, as defense-in-depth against a compromised or buggy upload response
/// planting an off-origin URL on ``FeedbackAttachment/url``:
/// - Same host (case-insensitive) is allowed.
/// - Otherwise both hosts must share the same registrable domain (public suffix
///   plus one label): the base's apex and its sibling subdomains are allowed,
///   e.g. `cdn.cupthread.com` or `cupthread.com` for base `api.cupthread.com`.
/// - Sharing only a public suffix or a multi-tenant hosting suffix is rejected:
///   `com`, `co.uk`, and `github.io` pair hosts that have no shared operator.
/// - IP-literal and single-label hosts fail closed.
func isAllowedDownloadHost(_ candidateHost: String, baseHost: String) -> Bool {
    guard let candidate = normalizedDownloadHost(candidateHost),
          let base = normalizedDownloadHost(baseHost) else {
        return false
    }
    if candidate == base {
        return true
    }
    let baseLabels = base.split(separator: ".")
    if !baseLabels.isEmpty, baseLabels.allSatisfy({ Int($0) != nil }) {
        return false // IP-literal base hosts have no registrable-domain relation.
    }
    guard let candidateDomain = registrableDomain(of: candidate),
          let baseDomain = registrableDomain(of: base) else {
        return false
    }
    return candidateDomain == baseDomain
}

private func normalizedDownloadHost(_ host: String) -> String? {
    var trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    while trimmed.hasSuffix(".") {
        trimmed.removeLast()
    }
    return trimmed.isEmpty ? nil : trimmed
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
