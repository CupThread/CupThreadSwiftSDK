import Foundation

// MARK: - Image fetch redirect policy (SEC-31)

/// Redirect policy for remote image transfers.
///
/// `RemoteImageLoader` accepts only HTTPS URLs, then hands the transfer to a
/// delegate-backed session. Without a redirect delegate URLSession follows any
/// 3xx to any host, port, or plain `http://` target, so the validated URL would
/// only cover the first hop. This policy keeps the whole transfer inside the
/// origin the loader validated:
///
/// - `https` on both sides, preserving the image-fetch HTTPS contract on every
///   hop;
/// - the same host, compared case-insensitively and exactly (no subdomain or
///   registrable-domain widening: image URLs are opaque content, so a redirect
///   may not introduce a host the caller never named);
/// - the same effective port, with 443 as the `https` default, so
///   `https://host/a` and `https://host:443/b` are one origin while
///   `https://host:8443/b` is not;
/// - no embedded userinfo credentials on either URL.
///
/// Anything else is refused before the target is contacted.
enum ImageFetchRedirectPolicy {
    /// Whether a redirect from `originalURL` to `redirectURL` may be followed.
    /// A missing URL, missing host, or non-`https` scheme never matches.
    static func isAllowed(originalURL: URL?, redirectURL: URL?) -> Bool {
        guard let originalURL, let redirectURL,
              originalURL.user == nil, originalURL.password == nil,
              redirectURL.user == nil, redirectURL.password == nil,
              originalURL.scheme?.lowercased() == "https",
              redirectURL.scheme?.lowercased() == "https",
              let originalHost = originalURL.host?.lowercased(),
              !originalHost.isEmpty,
              let redirectHost = redirectURL.host?.lowercased(),
              !redirectHost.isEmpty,
              originalHost == redirectHost
        else { return false }
        return effectivePort(of: originalURL) == effectivePort(of: redirectURL)
    }

    /// Effective port, so an omitted port equals the scheme's default.
    private static func effectivePort(of url: URL) -> Int {
        url.port ?? 443
    }
}
