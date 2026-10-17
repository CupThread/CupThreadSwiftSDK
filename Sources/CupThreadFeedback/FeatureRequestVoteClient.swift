import Foundation

// Extracted from FeatureRequestClient.swift so the list/propose plumbing and
// the vote endpoints each stay under the file-size budget.

private struct VotePayload: Encodable, Sendable {
    let appKey: String
    let userToken: String
    /// Omitted from the encoded JSON when `nil` (synthesized `Encodable`
    /// skips absent optionals), so the default vote payload keeps its exact
    /// historical shape.
    let shipNotifyEmail: String?
    /// Optional Cloudflare Turnstile token for human verification on anonymous
    /// votes and ship notification opt-ins (Issue #450, SaaS public API sync).
    /// Omitted from the encoded JSON when `nil` to preserve historical payload shape.
    let turnstileToken: String?
}

// MARK: - FeedbackClient voting extension

extension FeedbackClient {

    /// Sends a vote request with the specified HTTP method (`POST` to cast, `DELETE` to remove).
    private func sendVoteRequest(
        method: String,
        featureRequestId: String,
        userToken: String,
        shipNotifyEmail: String? = nil,
        turnstileToken: String? = nil
    ) async throws -> VoteResult {
        let trimmedID = featureRequestId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FeatureRequestIDGrammar.isValid(trimmedID) else {
            // An id that cannot be a single opaque path segment (API-24
            // grammar) can never name an existing request, and interpolating
            // it would alter the route while carrying the caller's tokens —
            // refuse locally, before the Turnstile provider is consulted or
            // any request is built (API-27). Same convention as
            // `fetchFeatureRequest`: report not-found.
            throw FeedbackClientError.featureRequestNotFound(message: nil, requestId: nil)
        }
        // Votes on a deleted/unapproved request are answered with the
        // documented JSON 404 envelope — map it to the typed case so callers
        // can catch `.featureRequestNotFound` instead of `.unexpectedStatus`
        // (API-27). Non-envelope 404s keep surfacing as `.unexpectedStatus`.
        let mapNotFound: (String, String?) -> FeedbackClientError = {
            FeedbackClientError.featureRequestNotFound(message: $0, requestId: $1)
        }
        let normalizedShipNotifyEmail = shipNotifyEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let normalizedTurnstileToken = turnstileToken?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        if method == "POST" {
            return try await sendVoteCastRequest(
                trimmedID: trimmedID,
                userToken: userToken,
                shipNotifyEmail: normalizedShipNotifyEmail,
                turnstileToken: normalizedTurnstileToken,
                mapNotFound: mapNotFound
            )
        } else {
            return try await sendVoteRemovalRequest(
                trimmedID: trimmedID,
                userToken: userToken,
                mapNotFound: mapNotFound
            )
        }
    }

    /// Sends the Turnstile-gated `POST` vote (SEC-90: one token verified once
    /// per request — the ship-notify binding passes both the opt-in-only
    /// challenge and the combined intake; a plain vote keeps the `vote`
    /// binding).
    private func sendVoteCastRequest(
        trimmedID: String,
        userToken: String,
        shipNotifyEmail: String?,
        turnstileToken: String?,
        mapNotFound: @escaping (String, String?) -> FeedbackClientError
    ) async throws -> VoteResult {
        let challenge = shipNotifyEmail == nil
            ? TurnstileChallenge.vote(appKey: configuration.appKey)
            : TurnstileChallenge.shipNotify(appKey: configuration.appKey)
        let data = try await sendWithTurnstileRetry(
            accepted: [200],
            challenge: challenge,
            initialToken: turnstileToken,
            mapResourceNotFound: mapNotFound
        ) { token, requestID in
            let payload = VotePayload(
                appKey: self.configuration.appKey,
                userToken: userToken,
                shipNotifyEmail: shipNotifyEmail,
                turnstileToken: token
            )
            var request = URLRequest(
                url: self.configuration.baseURL.appending(path: "/api/v1/feature-requests/\(trimmedID)/vote")
            )
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            try self.applyCorrelationHeaders(userToken: userToken, requestID: requestID, to: &request)
            await self.applyBearerToken(to: &request)
            request.httpBody = try self.encoder.encode(payload)
            return request
        }
        return try decodeSuccess(VoteResult.self, from: data)
    }

    /// Sends the idempotent `DELETE` vote removal (never Turnstile-gated).
    private func sendVoteRemovalRequest(
        trimmedID: String,
        userToken: String,
        mapNotFound: @escaping (String, String?) -> FeedbackClientError
    ) async throws -> VoteResult {
        let payload = VotePayload(
            appKey: configuration.appKey,
            userToken: userToken,
            shipNotifyEmail: nil,
            turnstileToken: nil
        )

        var request = URLRequest(
            url: configuration.baseURL.appending(path: "/api/v1/feature-requests/\(trimmedID)/vote")
        )
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try applyCorrelationHeaders(userToken: userToken, requestID: nextRequestID(), to: &request)
        await applyBearerToken(to: &request)
        request.httpBody = try encoder.encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }
        try validateResponse(
            httpResponse,
            data: data,
            accepted: [200],
            mapsPermissionErrors: true,
            mapResourceNotFound: mapNotFound
        )
        return try decodeSuccess(VoteResult.self, from: data)
    }

    /// Casts a vote on a feature request.
    ///
    /// The endpoint is insert-only and idempotent: repeating the request leaves
    /// an existing vote in place and returns the same response body
    /// (`{ "voted": true, "voteCount": <n> }`). To remove a vote, use
    /// ``removeVote(featureRequestId:userToken:)``.
    ///
    /// Authenticated callers attach the client's bearer token via the
    /// configured `authenticationProvider`.
    ///
    /// The vote endpoints are rate limited per client IP (20 requests/minute);
    /// exceeding the limit throws ``FeedbackClientError/rateLimited``, which
    /// the SDK surfaces as a friendly "try again in a minute" message rather
    /// than retrying in a tight loop.
    ///
    /// The vote request doubles as the ship-notification opt-in: when
    /// `shipNotifyEmail` is provided it enrolls the address in double-opt-in
    /// ship notifications — CupThread emails a single-use confirmation link,
    /// and only confirmed addresses are ever mailed when the request ships.
    /// The endpoint stays idempotent, so re-posting an existing vote with a
    /// `shipNotifyEmail` only processes the opt-in; callers can therefore
    /// offer an "email me when this ships" prompt after a successful vote
    /// without toggling anything. The value is trimmed, and a whitespace-only
    /// value is treated as `nil` (the field is omitted from the JSON body).
    ///
    /// When human verification applies, anonymous voters on apps with
    /// ``PublicAppConfig/requireAnonymousVoteTurnstile`` and voters
    /// providing `shipNotifyEmail` should supply a Turnstile token via
    /// `turnstileToken`. When omitted and a `turnstileTokenProvider` is
    /// configured, a `shipNotifyEmail` opt-in consults the provider with
    /// ``TurnstileChallenge/shipNotify(appKey:)`` and a plain vote with
    /// ``TurnstileChallenge/vote(appKey:)`` — the endpoint verifies its
    /// single token exactly once per request (SEC-90), and the ship-notify
    /// binding is the only one its opt-in challenge accepts on boards
    /// without anonymous-vote Turnstile.
    ///
    /// On boards that require signed-in voting, the server accepts a
    /// `shipNotifyEmail` only when it is one of the signed-in session's
    /// verified addresses; a mismatched address still records the vote but
    /// answers with a ``VoteResult/warning``
    /// (``VoteWarning/isEmailNotVerified``) and stores no ship-notification
    /// consent. The built-in ``FeatureRequestsView`` flow never sends the
    /// field, so it never receives a warning; the warning is decoded for
    /// callers that opt in through this method or post votes through their
    /// own transport.
    /// - Parameters:
    ///   - featureRequestId: Id of the request to vote on. Values that cannot
    ///     be a valid feature-request id (empty, whitespace, or containing
    ///     path/query/percent characters — API-24 grammar) throw
    ///     ``FeedbackClientError/featureRequestNotFound(message:requestId:)``
    ///     locally, before any request is sent.
    ///   - userToken: A stable UUID string identifying this user.
    ///   - shipNotifyEmail: Optional email address (max 254 characters) to
    ///     enroll in ship notifications for this request; `nil` keeps the
    ///     payload unchanged and sends no opt-in.
    ///   - turnstileToken: Optional Cloudflare Turnstile token for human
    ///     verification when voting anonymously or opting in to ship
    ///     notifications. When omitted and a `turnstileTokenProvider` is
    ///     configured, a token is resolved automatically.
    /// - Returns: The new vote state, the request's authoritative vote count,
    ///   and any non-fatal warning the server attached.
    /// - Throws: ``FeedbackClientError/featureRequestNotFound(message:requestId:)``
    ///   when the server answers HTTP 404 with the documented JSON error
    ///   envelope (the request was deleted, is unapproved, or never existed —
    ///   API-27), or locally with no request sent when `featureRequestId`
    ///   cannot be a valid id,
    ///   ``FeedbackClientError/rateLimited`` on HTTP 429,
    ///   ``FeedbackClientError/turnstileRequired(message:requestId:)`` when human
    ///   verification is required or rejected (HTTP 403 `turnstile_verification_failed`),
    ///   ``FeedbackClientError/authenticationRequired`` or
    ///   ``FeedbackClientError/forbidden(message:requestId:)`` when anonymous
    ///   voting is disabled for the app (HTTP 401/403),
    ///   ``FeedbackClientError/unexpectedStatus(code:message:requestId:)`` or
    ///   ``FeedbackClientError/invalidResponse``.
    public func castVote(
        featureRequestId: String,
        userToken: String,
        shipNotifyEmail: String? = nil,
        turnstileToken: String? = nil
    ) async throws -> VoteResult {
        try await sendVoteRequest(
            method: "POST",
            featureRequestId: featureRequestId,
            userToken: userToken,
            shipNotifyEmail: shipNotifyEmail,
            turnstileToken: turnstileToken
        )
    }

    /// Removes the current user's vote on a feature request.
    ///
    /// The endpoint is idempotent: removing a vote that is not present returns
    /// `{ "voted": false, "voteCount": <n> }` with HTTP 200 rather than an
    /// error. Authenticated callers attach the client's bearer token via the
    /// configured `authenticationProvider`.
    ///
    /// The vote endpoints are rate limited per client IP (20 requests/minute);
    /// exceeding the limit throws ``FeedbackClientError/rateLimited``.
    /// - Parameters:
    ///   - featureRequestId: Id of the request to unvote. Values that cannot
    ///     be a valid feature-request id (empty, whitespace, or containing
    ///     path/query/percent characters — API-24 grammar) throw
    ///     ``FeedbackClientError/featureRequestNotFound(message:requestId:)``
    ///     locally, before any request is sent.
    ///   - userToken: A stable UUID string identifying this user.
    /// - Returns: The new vote state (`voted: false`) and authoritative vote count.
    /// - Throws: ``FeedbackClientError/featureRequestNotFound(message:requestId:)``
    ///   when the server answers HTTP 404 with the documented JSON error
    ///   envelope (the request was deleted, is unapproved, or never existed —
    ///   API-27), or locally with no request sent when `featureRequestId`
    ///   cannot be a valid id,
    ///   ``FeedbackClientError/rateLimited`` on HTTP 429,
    ///   ``FeedbackClientError/authenticationRequired`` or
    ///   ``FeedbackClientError/forbidden(message:requestId:)`` when anonymous
    ///   voting is disabled for the app (HTTP 401/403),
    ///   ``FeedbackClientError/unexpectedStatus(code:message:requestId:)`` or
    ///   ``FeedbackClientError/invalidResponse``.
    public func removeVote(
        featureRequestId: String,
        userToken: String
    ) async throws -> VoteResult {
        try await sendVoteRequest(
            method: "DELETE",
            featureRequestId: featureRequestId,
            userToken: userToken,
            shipNotifyEmail: nil,
            turnstileToken: nil
        )
    }

    /// Casts a vote on a feature request (legacy shim).
    ///
    /// The backend vote endpoint is now insert-only and no longer toggles.
    /// Use ``castVote(featureRequestId:userToken:shipNotifyEmail:turnstileToken:)`` to cast
    /// and ``removeVote(featureRequestId:userToken:)`` to remove.
    @available(*, deprecated, message: "Use castVote or removeVote instead. The vote endpoint is insert-only (CupThread/SaaS#406).")
    public func toggleVote(
        featureRequestId: String,
        userToken: String,
        shipNotifyEmail: String? = nil,
        turnstileToken: String? = nil
    ) async throws -> VoteResult {
        try await castVote(
            featureRequestId: featureRequestId,
            userToken: userToken,
            shipNotifyEmail: shipNotifyEmail,
            turnstileToken: turnstileToken
        )
    }
}
