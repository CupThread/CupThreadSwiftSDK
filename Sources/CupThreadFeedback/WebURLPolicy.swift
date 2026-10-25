import Foundation
import SwiftUI

// MARK: - URL Policy

/// Checks whether a URL is an allowed web URL:
/// - Must have `http` or `https` scheme.
/// - Must have a non-empty, non-whitespace host.
/// - Must not contain embedded user credentials (`user` or `password`).
func isAllowedWebURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines),
          !host.isEmpty,
          url.user == nil,
          url.password == nil else {
        return false
    }
    return true
}

/// Checks whether a URL is an allowed secure remote image URL:
/// - Must have `https` scheme.
/// - Must have a non-empty, non-whitespace host.
/// - Must not contain embedded credentials (user or password).
func isAllowedSecureImageURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(),
          scheme == "https",
          let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines),
          !host.isEmpty,
          url.user == nil,
          url.password == nil else {
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
/// - If already an allowed `http` or `https` URL with a valid host and without embedded credentials, returns it.
/// - If it contains a disallowed scheme (such as `tel:`, `javascript:`, `shortcuts://`, or custom schemes), returns `nil`.
/// - If it is scheme-less or protocol-relative (e.g. `example.com` or `//example.com`), prefixes `https://` and validates.
func normalizeWebsiteURL(_ string: String) -> URL? {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let candidate = URL(string: trimmed), let scheme = candidate.scheme {
        let lower = scheme.lowercased()
        if lower == "http" || lower == "https" {
            guard isAllowedWebURL(candidate) else {
                return nil
            }
            return candidate
        } else {
            // Disallowed scheme
            return nil
        }
    }

    // Scheme-less or protocol-relative: strip leading slashes before prefixing https://
    let stripped = trimmed.drop(while: { $0 == "/" })
    guard !stripped.isEmpty,
          let url = URL(string: "https://" + stripped),
          isAllowedWebURL(url) else {
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
/// requires matching full registrable domains instead. Matching walks the
/// longest listed suffix (``publicSuffixLabelCount(of:)``), so the multi-label
/// service suffixes below shadow the two-label entry they sit on and sibling
/// tenants of a hosted service (two S3 buckets, for example) never collapse
/// into one registrable domain. Hosting suffixes missing from this curated set
/// (e.g. `amplifyapp.com`) still collapse onto their apex — a recorded
/// limitation of the zero-dependency approximation, not an endorsement
/// (issue #594).
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

/// Checks whether a normalized host string represents an IP literal (IPv4 or IPv6).
/// IP literals cannot establish a registrable-domain relationship with any other host.
private func isIPLiteral(_ host: String) -> Bool {
    if host.contains(":") || host.contains("[") || host.contains("]") {
        return true
    }
    let labels = host.split(separator: ".")
    return !labels.isEmpty && labels.allSatisfy { Int($0) != nil }
}

/// Returns the label count of the longest curated public suffix that `labels`
/// ends with, or `nil` when no curated entry matches. Multi-label service
/// suffixes are matched before the two-label entries so the deepest listed
/// suffix wins (issue #594).
private func publicSuffixLabelCount(of labels: [Substring]) -> Int? {
    let count = labels.count
    guard count >= 2 else {
        return nil
    }
    if let serviceCount = servicePublicSuffixLabelCount(of: labels) {
        return serviceCount
    }
    let lastTwo = labels.suffix(2).joined(separator: ".")
    if multiTenantHostSuffixes.contains(lastTwo)
        || registrySecondLevelLabels.contains(String(labels[count - 2])) {
        return 2
    }
    return nil
}

/// Label count for the object-storage services whose Public Suffix List entries
/// make every bucket its own site: `r2.cloudflarestorage.com` and the S3 family
/// `s3(-…)?(.dualstack)?.<region>.amazonaws.com`. The region label is
/// arbitrary, so these are matched structurally instead of enumerated
/// (issue #594).
private func servicePublicSuffixLabelCount(of labels: [Substring]) -> Int? {
    let count = labels.count
    guard count >= 3 else {
        return nil
    }
    let lastTwo = labels.suffix(2).joined(separator: ".")
    if lastTwo == "cloudflarestorage.com", labels[count - 3] == "r2" {
        return 3
    }
    guard lastTwo == "amazonaws.com" else {
        return nil
    }
    func isS3ServiceLabel(_ label: Substring) -> Bool {
        label == "s3" || label.hasPrefix("s3-")
    }
    if isS3ServiceLabel(labels[count - 3]) {
        return 3 // `s3.amazonaws.com`
    }
    if count >= 4, isS3ServiceLabel(labels[count - 4]) {
        return 4 // `s3.<region>.amazonaws.com`
    }
    if count >= 5, isS3ServiceLabel(labels[count - 5]), labels[count - 4] == "dualstack" {
        return 5 // `s3.dualstack.<region>.amazonaws.com`
    }
    return nil
}

/// Returns the registrable domain (public suffix plus one label) of `host`, or
/// `nil` when `host` is itself a bare public suffix and cannot establish
/// same-site trust. Hosts under a multi-label object-storage service suffix are
/// their own registrable domain: the tenant is the bucket and bucket names may
/// contain dots (`a.b.s3.us-east-1.amazonaws.com`), so no two distinct hosts
/// below a service suffix ever share one.
private func registrableDomain(of host: String) -> String? {
    guard !isIPLiteral(host) else {
        return nil
    }
    let labels = host.split(separator: ".")
    guard labels.count >= 2 else {
        return nil // A single label is a bare TLD (or an intranet host), never registrable.
    }
    guard let publicSuffixCount = publicSuffixLabelCount(of: labels) else {
        return labels.suffix(2).joined(separator: ".")
    }
    // Under a public suffix the registrable domain needs one more label; the
    // bare suffix itself (`co.uk`, `s3.us-east-1.amazonaws.com`) has none.
    guard labels.count > publicSuffixCount else {
        return nil
    }
    if servicePublicSuffixLabelCount(of: labels) != nil {
        // Below a hosted object-storage suffix the tenant is the bucket, and
        // bucket names may themselves contain dots (`a.b.s3.…`), so the whole
        // host is the tenant identity — no subdomain trust under a service.
        return labels.joined(separator: ".")
    }
    return labels.suffix(publicSuffixCount + 1).joined(separator: ".")
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
    if isIPLiteral(candidate) || isIPLiteral(base) {
        return false // IP-literal hosts have no registrable-domain relation.
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
    if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") && trimmed.count >= 2 {
        trimmed = String(trimmed.dropFirst().dropLast())
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
