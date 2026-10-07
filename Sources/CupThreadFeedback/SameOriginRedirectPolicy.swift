import Foundation

// MARK: - Same-origin redirect policy (SEC-11)

/// The `URLSessionTaskDelegate` installed on the SDK's default session to
/// refuse cross-origin HTTP redirects.
///
/// `URLSession`'s default behavior follows 3xx redirects and rebuilds the
/// redirected request from the original one — re-sending every header,
/// including `Authorization: Bearer …` and `X-User-Token`, to whatever host
/// the `Location` header names, and on 307/308 re-sending the method **and
/// the body**. Foundation does not implement the browser rule that strips
/// authorization headers on cross-origin redirects, so a compromised or
/// misconfigured API origin — or an open redirect on it — could otherwise
/// deliver credentials and upload bytes to a third-party host, bypassing
/// every origin check the SDK performs before issuing a request.
///
/// A redirect is followed only when the redirect target's origin — scheme
/// (case-insensitive), host (case-insensitive), and effective port with the
/// `http`/`https` defaults 80/443 — equals the origin of the task's original
/// request. Anything else (a hop to another host, a port change, or a
/// `https → http` downgrade) is refused by passing `nil` to the completion
/// handler: URLSession then surfaces the 3xx response itself as the final
/// response, which response validation maps to
/// ``FeedbackClientError/unexpectedStatus(code:message:requestId:)`` — there
/// is no silent success path.
///
/// Sessions injected through `FeedbackClient.init(session:)` are not touched;
/// install this delegate (or an equivalent policy) on such sessions to opt
/// them into the same guarantee.
final class SameOriginRedirectLimiter: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// The redirect policy for one redirect decision: `true` when
    /// `redirectURL` stays within `originalURL`'s origin and the task may
    /// follow it. `nil` URLs (either side, or a URL without scheme or host)
    /// never match.
    static func isSameOrigin(_ originalURL: URL?, redirectURL: URL?) -> Bool {
        guard let originalURL, let redirectURL,
              let originalScheme = originalURL.scheme?.lowercased(),
              let redirectScheme = redirectURL.scheme?.lowercased(),
              originalScheme == redirectScheme,
              let originalHost = originalURL.host?.lowercased(),
              !originalHost.isEmpty,
              let redirectHost = redirectURL.host?.lowercased(),
              !redirectHost.isEmpty,
              originalHost == redirectHost
        else { return false }
        return effectivePort(of: originalURL, scheme: originalScheme)
            == effectivePort(of: redirectURL, scheme: redirectScheme)
    }

    /// Effective port with the schemes' defaults, so `https://host` and
    /// `https://host:443` are one origin (and likewise for `http` and 80).
    private static func effectivePort(of url: URL, scheme: String) -> Int {
        url.port ?? (scheme == "https" ? 443 : 80)
    }
}

extension SameOriginRedirectLimiter {
    /// Follows the redirect only when it stays within the original request's
    /// origin; otherwise refuses it, so the 3xx response itself is delivered
    /// and validated like any other non-accepted status.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard Self.isSameOrigin(task.originalRequest?.url, redirectURL: request.url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
