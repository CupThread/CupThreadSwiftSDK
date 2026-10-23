import Foundation

// MARK: - End-user self-service endpoints (/api/v1/me/*)

/// Result of `POST /api/v1/me/erase`.
public struct DataErasureResult: Codable, Equatable, Sendable {
    /// Whether the profile was erased. `false` when no profile matched the
    /// identity (e.g. replaying after a successful erase).
    public let erased: Bool
    /// The erased end-user profile id, when one existed.
    public let endUserId: String?
    /// Whether the *local* cleanup that follows an erasure — dropping the
    /// anonymous identity and the remembered changelog-subscription email —
    /// could not be confirmed because the Keychain refused the deletions
    /// (e.g. locked before first unlock) (SEC-29).
    ///
    /// The server-side erasure itself succeeded; only the on-device records
    /// are still present. The next ``FeedbackClient/eraseMyData(store:)``
    /// call retries the cleanup (even on an `erased: false` replay), so the
    /// host should invoke it again once the Keychain is readable instead of
    /// treating this as a failed erasure.
    public let localCleanupPending: Bool

    /// Creates a result. `localCleanupPending` defaults to `false`; the
    /// server-facing initializers keep it local-only.
    init(erased: Bool, endUserId: String?, localCleanupPending: Bool = false) {
        self.erased = erased
        self.endUserId = endUserId
        self.localCleanupPending = localCleanupPending
    }

    private enum CodingKeys: String, CodingKey {
        case erased, endUserId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        erased = try container.decode(Bool.self, forKey: .erased)
        endUserId = try container.decodeIfPresent(String.self, forKey: .endUserId)
        localCleanupPending = false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(erased, forKey: .erased)
        try container.encodeIfPresent(endUserId, forKey: .endUserId)
    }
}

/// Persists whether a completed `eraseMyData` round trip left local PII
/// cleanup unconfirmed (SEC-29).
///
/// A transient Keychain failure (locked before first unlock, entitlement
/// errors) can make `UserTokenStore.reset()` or
/// `ChangelogSubscriptionStore.clear()` report an unconfirmed deletion after
/// the server already erased the profile. The flag makes the next
/// `eraseMyData(store:)` call retry the cleanup even when the idempotent
/// replay answers `erased: false`, so one transient failure cannot strand
/// the identity or the subscriber email on the device.
struct DataErasureCleanupState {
    private static func key(for appKey: String) -> String {
        "com.cupthread.feedback.erasureCleanupPending.\(AppKeyGrammar.normalized(appKey))"
    }

    let defaults: UserDefaults
    let key: String

    init(appKey: String, defaults: UserDefaults = .standard) {
        // Normalized like the other per-app-key storage identities (SEC-22)
        // so a whitespace-padded app key cannot alias the marker.
        self.key = Self.key(for: appKey)
        self.defaults = defaults
    }

    /// Whether a previous erasure left local cleanup unconfirmed.
    var isPending: Bool {
        defaults.bool(forKey: key)
    }

    func setPending(_ pending: Bool) {
        if pending {
            defaults.set(true, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

/// Result of `POST /api/v1/me/link`.
public struct EndUserLinkResult: Codable, Equatable, Sendable {
    /// Whether the profile was linked to the authenticated identity.
    public let linked: Bool
    /// The linked end-user profile id.
    public let endUserId: String?
    /// The authenticated user id the profile is now linked to, as reported
    /// for the caller's own session. Unlike the user IDs on public payloads
    /// (``UserProfile/clerkUserId``, ``FeatureRequestItem/requesterClerkId``,
    /// …), this is not the app-scoped pseudonym shown on the public board —
    /// never compare it against identifiers from public responses.
    public let clerkUserId: String?
}

private struct MeAppKeyPayload: Encodable, Sendable {
    let appKey: String
}

extension FeedbackClient {

    /// Erases the calling end user's profile for this app (self-service data
    /// erasure).
    ///
    /// The anonymous token is rotated server-side — the old token stops
    /// working immediately — stored PII is removed, and the user's feature
    /// requests, votes, and comments are anonymized while aggregate counts
    /// are preserved.
    ///
    /// When an `authenticationProvider` is configured and resolves to a
    /// token, it is presented as `Authorization: Bearer …` so a signed-in
    /// user's data is erased by identity: every end-user profile linked to
    /// that authenticated identity in this app, not just the row keyed to
    /// this device's anonymous token. The `X-User-Token` header is always
    /// sent, so the device's anonymous row is covered either way. Hosts of
    /// signed-in users should ensure the provider can return a fresh token
    /// at erase time — with a provider configured but no token resolved,
    /// only the anonymous row is addressed and a server `404` (nothing
    /// matched this device) surfaces as `erased: false`.
    ///
    /// - Parameter userToken: Anonymous user token sent as `X-User-Token`.
    ///   Blank, whitespace-only, or multi-line values are rejected locally —
    ///   the header plumbing would silently drop them and dispatch the
    ///   erasure without any identity (#417).
    /// - Returns: Whether a profile was erased. A `404` from the server is
    ///   normalized to `erased: false` rather than an error, so replaying an
    ///   erase is idempotent from the caller's perspective.
    /// - Throws: ``FeedbackClientError/authenticationRequired`` when
    ///   `userToken` is blank, whitespace-only, or contains a newline (all
    ///   rejected before any network round trip), or when the
    ///   identity is missing or rejected (HTTP 401),
    ///   ``FeedbackClientError/forbidden(message:requestId:)`` when the app
    ///   disables self-service erasure (HTTP 403),
    ///   ``FeedbackClientError/rateLimited`` on HTTP 429, or
    ///   ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``
    ///   / ``FeedbackClientError/invalidResponse``.
    public func eraseMyData(userToken: String) async throws -> DataErasureResult {
        // A blank or multi-line token would be silently dropped by
        // applyUserToken, dispatching the erasure without any identity —
        // fail fast locally instead of letting the server 401 (#417).
        let identityToken = try validatedUserToken(userToken)
        var request = URLRequest(url: configuration.baseURL.appending(path: "/api/v1/me/erase"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try applyCorrelationHeaders(userToken: identityToken, requestID: nextRequestID(), to: &request)
        await applyBearerToken(to: &request)
        request.httpBody = try encoder.encode(MeAppKeyPayload(appKey: configuration.appKey))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }
        if httpResponse.statusCode == 404 {
            // No profile matched the identity — nothing to erase.
            return DataErasureResult(erased: false, endUserId: nil)
        }
        // The route's 401/403 mean the identity is missing or the app
        // disabled self-service erasure; map them to the typed permission
        // errors like the sibling identity-bound endpoints (#359).
        try validateResponse(httpResponse, data: data, accepted: [200], mapsPermissionErrors: true)
        return try decodeSuccess(DataErasureResult.self, from: data)
    }

    /// Erases the end user's profile using the identity held by a
    /// ``UserTokenStore``, and drops the store's identity after a successful
    /// erasure.
    ///
    /// The server rotates the anonymous token on erasure — the old token
    /// stops working immediately — so this overload calls
    /// ``UserTokenStore/reset()`` when the response reports `erased: true`;
    /// the next ``UserTokenStore/token`` read mints a fresh identity and the
    /// revoked one is never replayed. The locally remembered changelog
    /// subscription email (see ``ChangelogSubscriptionStore``) is cleared at
    /// the same time so no PII survives a confirmed erasure on the device.
    /// When the result is `erased: false` (no profile matched the identity),
    /// both stores are left untouched.
    ///
    /// Local cleanup is confirmed, not best-effort: when the Keychain refuses
    /// the deletions (e.g. locked before first unlock), the returned result
    /// reports `localCleanupPending == true` and a cleanup-pending marker is
    /// persisted. The next ``eraseMyData(store:)`` call retries the cleanup —
    /// including on the idempotent `erased: false` replay — so a single
    /// transient Keychain failure cannot leave the identity or the subscriber
    /// email stranded on the device (SEC-29).
    ///
    /// Like ``eraseMyData(userToken:)``, a resolved authentication-provider
    /// token is presented as `Authorization: Bearer …`, so for a signed-in
    /// user erasure covers every profile linked to their identity in this
    /// app plus this device's anonymous row. With a provider configured but
    /// no token resolved, only the anonymous row is addressed.
    ///
    /// - Parameter store: The store whose identity is erased and reset.
    /// - Returns: Whether a profile was erased, plus
    ///   ``DataErasureResult/localCleanupPending`` when the on-device cleanup
    ///   still needs a retry.
    /// - Throws: Same errors as ``eraseMyData(userToken:)``.
    public func eraseMyData(store: UserTokenStore) async throws -> DataErasureResult {
        try await eraseMyData(
            store: store,
            subscriptionStore: ChangelogSubscriptionStore(appKey: configuration.appKey),
            cleanupState: DataErasureCleanupState(appKey: configuration.appKey)
        )
    }

    /// Test seam for ``eraseMyData(store:)``: the same erasure flow with an
    /// injectable subscription store. `nil` skips the local subscription
    /// cleanup. `cleanupState` backs the cleanup-pending marker; `nil`
    /// disables marker persistence (unit tests that don't exercise the
    /// retry path).
    func eraseMyData(
        store: UserTokenStore,
        subscriptionStore: ChangelogSubscriptionStore?,
        cleanupState: DataErasureCleanupState? = nil
    ) async throws -> DataErasureResult {
        let result = try await eraseMyData(userToken: store.token)
        // A previous call may have failed to confirm local cleanup (locked
        // Keychain); its marker forces the idempotent `erased: false` replay
        // to retry the cleanup instead of skipping it (#496).
        guard result.erased || (cleanupState?.isPending ?? false) else {
            return result
        }
        let identityReset = store.reset()
        let subscriptionCleared = subscriptionStore?.clear() ?? true
        let cleanupPending = !(identityReset && subscriptionCleared)
        cleanupState?.setPending(cleanupPending)
        return DataErasureResult(
            erased: result.erased,
            endUserId: result.endUserId,
            localCleanupPending: cleanupPending
        )
    }

    /// Links the anonymous end-user profile to an authenticated user session
    /// (e.g. a social-login Clerk session token), for apps that let users
    /// transition from anonymous voting/feedback to authenticated accounts.
    ///
    /// - Parameters:
    ///   - sessionToken: The authenticated session token, sent as
    ///     `Authorization: Bearer <sessionToken>`. Blank, whitespace-only, or
    ///     multi-line values are rejected locally — a blank session would
    ///     dispatch `Bearer ` with no identity, and a newline can never be
    ///     carried as a header value (#416).
    ///   - userToken: Anonymous user token sent as `X-User-Token`. Blank,
    ///     whitespace-only, or multi-line values are rejected locally — the
    ///     header plumbing would silently drop them and dispatch the link
    ///     with no anonymous identity to attach (#416).
    /// - Returns: The confirmed link, including the authenticated identity.
    /// - Note: The Clerk session bearer is never re-sent to a redirect
    ///   target: a redirect off the configured API origin is refused and the
    ///   3xx response surfaces as
    ///   ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``.
    /// - Throws: ``FeedbackClientError/authenticationRequired`` when
    ///   `sessionToken` or `userToken` is blank, whitespace-only, or
    ///   contains a newline (all rejected before any network round trip),
    ///   when the session is missing or invalid (HTTP 401),
    ///   ``FeedbackClientError/forbidden(message:requestId:)`` when the
    ///   server policy forbids the link (HTTP 403),
    ///   ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``
    ///   with status 404 for an unknown `appKey` **or** an app whose public
    ///   surfaces are disabled — the API answers both with the same
    ///   `"App not found"` body by design, so callers must treat the two as
    ///   one outcome (issue #504) — and with status 409 when the profile is
    ///   already confirmed to a different identity, or
    ///   ``FeedbackClientError/invalidResponse``.
    public func linkEndUser(
        sessionToken: String,
        userToken: String
    ) async throws -> EndUserLinkResult {
        // A blank session token would go out as `Bearer ` and can only come
        // back 401; a newline-containing one can never be carried as a
        // header value. A blank userToken would be silently dropped by
        // applyUserToken, dispatching the link with no anonymous identity
        // to attach. Fail fast locally instead (#416) — the trimmed values
        // are what get sent, so both headers always carry the same identity
        // the caller validated.
        let sessionBearer = try validatedUserToken(sessionToken)
        let identityToken = try validatedUserToken(userToken)
        var request = URLRequest(url: configuration.baseURL.appending(path: "/api/v1/me/link"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(sessionBearer)", forHTTPHeaderField: "Authorization")
        try applyCorrelationHeaders(userToken: identityToken, requestID: nextRequestID(), to: &request)
        request.httpBody = try encoder.encode(MeAppKeyPayload(appKey: configuration.appKey))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }
        // The route's 401/403 mean the session is missing or the server
        // policy forbids the link; map them to the typed permission errors
        // like the sibling identity-bound endpoints (#359).
        try validateResponse(httpResponse, data: data, accepted: [200], mapsPermissionErrors: true)
        return try decodeSuccess(EndUserLinkResult.self, from: data)
    }
}
