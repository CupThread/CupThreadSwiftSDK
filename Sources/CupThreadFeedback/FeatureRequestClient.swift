import Foundation

// MARK: - Private payload types

private struct FeatureRequestSubmitPayload: Encodable, Sendable {
    let appKey: String
    let title: String
    let description: String
    let requesterName: String?
    let requesterToken: String
    let turnstileToken: String?
}

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

// MARK: - FeedbackClient extension

extension FeedbackClient {

    /// Fetches the feature requests list for the configured app.
    ///
    /// Results include each request's vote count and whether the current user
    /// already voted (`hasVoted`), which is why the call requires a
    /// `userToken`. The token is sent as the `X-User-Token` header — passing
    /// it in the URL query string is deprecated by the API to keep tokens out
    /// of access logs and referrers. When configured with an authentication
    /// provider, the signed-in user's bearer token is attached as
    /// `Authorization: Bearer …` so listing and searching succeed when
    /// `allowAnonymousRoadmap = false`.
    /// - Parameters:
    ///   - userToken: A stable UUID string identifying this user (for own pending requests and vote state).
    ///   - limit: Maximum number of results to return.
    ///   - offset: Pagination offset.
    ///   - versionId: Optional version filter (see `fetchVersions()`).
    ///   - query: Optional server-side search over title and description
    ///     (rate-limited per IP and briefly cached by the backend).
    ///   - cursor: Opaque keyset cursor from a previous page's
    ///     ``ListFeatureRequestsResult/nextCursor`` — the cheaper way to page
    ///     deeply; takes the place of large `offset` values.
    /// - Returns: The matching requests, the unpaginated `total`, and cursor
    ///   paging fields.
    /// - Throws: ``FeedbackClientError/authenticationRequired`` or
    ///   ``FeedbackClientError/forbidden(message:requestId:)`` when anonymous
    ///   access is disabled for the app (HTTP 401/403),
    ///   ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``
    ///   or ``FeedbackClientError/invalidResponse``.
    public func fetchFeatureRequests(
        userToken: String,
        limit: Int = 50,
        offset: Int = 0,
        versionId: String? = nil,
        query: String? = nil,
        cursor: String? = nil
    ) async throws -> ListFeatureRequestsResult {
        let base = configuration.baseURL.appending(path: "/api/v1/feature-requests")
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: true) else {
            throw FeedbackClientError.invalidResponse
        }
        var queryItems = [
            URLQueryItem(name: "appKey", value: configuration.appKey),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset))
        ]
        if let versionId {
            queryItems.append(URLQueryItem(name: "versionId", value: versionId))
        }
        if let query, !query.isEmpty {
            queryItems.append(URLQueryItem(name: "q", value: query))
        }
        if let cursor, !cursor.isEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw FeedbackClientError.invalidResponse
        }

        var request = URLRequest(url: url)
        applyCorrelationHeaders(userToken: userToken, requestID: nextRequestID(), to: &request)
        await applyBearerToken(to: &request)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }
        try validateResponse(httpResponse, data: data, accepted: [200], mapsPermissionErrors: true)
        return try decoder.decode(ListFeatureRequestsResult.self, from: data)
    }

    /// Fetches a single feature request by its id (`GET /api/v1/feature-requests/{id}`).
    ///
    /// Deep links, notification routing, and share links can fetch an individual
    /// request directly rather than paging the entire board listing.
    ///
    /// When `userToken` is provided, the returned request includes personalized
    /// vote state (``FeatureRequestItem/hasVoted``) and ownership
    /// (``FeatureRequestItem/isOwnRequest``). When omitted or `nil`, both fields
    /// are `false`. When the client is configured with an authentication provider,
    /// the signed-in user's bearer token is attached so requests succeed when
    /// `allowAnonymousRoadmap = false`.
    ///
    /// - Parameters:
    ///   - id: The stable request id (as returned by ``fetchFeatureRequests(userToken:limit:offset:versionId:query:cursor:)``
    ///     or in push/deep-link payloads).
    ///   - userToken: Optional stable UUID string identifying this user.
    /// - Returns: The matching feature request.
    /// - Throws: ``FeedbackClientError/featureRequestNotFound(message:requestId:)``
    ///   when the server answers HTTP 404 with the documented JSON error
    ///   envelope (the request does not exist, is unapproved, or belongs to
    ///   an app with public access disabled), or locally with no request
    ///   sent when `id` cannot be a valid feature-request id (empty,
    ///   whitespace-padded to nothing, or containing path/query/percent
    ///   characters — deep-link ids are untrusted input),
    ///   ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``
    ///   when a 404 arrives *without* the JSON envelope (router fallback,
    ///   deploy skew, or a wrong `baseURL` — distinguishable from a real
    ///   missing request),
    ///   ``FeedbackClientError/authenticationRequired`` or
    ///   ``FeedbackClientError/forbidden(message:requestId:)`` when anonymous access
    ///   is disabled for the app (HTTP 401/403),
    ///   ``FeedbackClientError/rateLimited(message:requestId:)`` when the per-client-IP
    ///   rate limit is exceeded (HTTP 429),
    ///   or ``FeedbackClientError/invalidResponse`` when a success body or
    ///   any other response cannot be decoded.
    public func fetchFeatureRequest(
        id: String,
        userToken: String? = nil
    ) async throws -> FeatureRequestItem {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FeatureRequestIDGrammar.isValid(trimmedID) else {
            // Deep-link ids are untrusted input (API-24): an id that cannot
            // be a single opaque path segment can never name an existing
            // request, so report not-found without building a URL from it.
            throw FeedbackClientError.featureRequestNotFound(message: nil, requestId: nil)
        }
        let url = configuration.baseURL.appending(path: "/api/v1/feature-requests/\(trimmedID)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyCorrelationHeaders(userToken: userToken, requestID: nextRequestID(), to: &request)
        await applyBearerToken(to: &request)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }
        if httpResponse.statusCode == 404,
           let envelope = try? decoder.decode(APIErrorEnvelope.self, from: data),
           let message = envelope.error?.nilIfEmpty {
            // Only the API's documented resource-404 envelope means "this
            // request does not exist". A bare router fallback (text/plain
            // "404 Not Found", empty body — what production answers on
            // deploy skew or a wrong baseURL) falls through to
            // `validateResponse` and surfaces as `.unexpectedStatus`.
            throw FeedbackClientError.featureRequestNotFound(
                message: message,
                requestId: httpResponse.cupthreadRequestID
            )
        }
        try validateResponse(httpResponse, data: data, accepted: [200], mapsPermissionErrors: true)
        do {
            let result = try decoder.decode(FeatureRequestResponse.self, from: data)
            return result.request
        } catch {
            throw FeedbackClientError.invalidResponse
        }
    }

    /// Fetches a single feature request by its id (alias for ``fetchFeatureRequest(id:userToken:)``).
    ///
    /// - Parameters:
    ///   - id: The stable request id.
    ///   - userToken: Optional stable UUID string identifying this user.
    /// - Returns: The matching feature request.
    public func getFeatureRequest(
        id: String,
        userToken: String? = nil
    ) async throws -> FeatureRequestItem {
        try await fetchFeatureRequest(id: id, userToken: userToken)
    }

    /// Submits a new feature request. It will be pending until approved by an admin.
    ///
    /// Titles and descriptions are trimmed; an empty `requesterName` is sent
    /// as anonymous. The submitting user is recorded via `userToken`, which
    /// is also how the console recognizes "own" requests (those can't be
    /// self-voted). Authenticated callers attach the client's bearer token
    /// via the configured `authenticationProvider`.
    /// - Parameters:
    ///   - draft: Title, description, and optional requester name.
    ///   - userToken: A stable UUID string identifying this user.
    /// - Returns: The created request's id and whether it is pending review.
    /// - Throws: ``FeedbackClientError/submissionQuotaExceeded(message:)`` when
    ///   the app's workspace has reached its monthly submission quota
    ///   (HTTP 402 `tier_limit_submissions`),
    ///   ``FeedbackClientError/subscriptionInactive(message:)`` when the
    ///   workspace subscription is inactive or canceled (HTTP 402
    ///   `subscription_inactive`),
    ///   ``FeedbackClientError/turnstileRequired(message:requestId:)`` when the
    ///   server's Turnstile gate rejects the submission and no fresh token
    ///   could be presented (HTTP 403),
    ///   ``FeedbackClientError/authenticationRequired`` or
    ///   ``FeedbackClientError/forbidden(message:requestId:)`` when anonymous
    ///   feedback is disabled for the app (HTTP 401/403),
    ///   ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``
    ///   or ``FeedbackClientError/invalidResponse``, or
    ///   ``FeedbackClientError/textTooLong`` when the encoded payload exceeds
    ///   the client-side intake byte budget (BUG-18) — rejected locally with
    ///   no network round trip; shorten the title/description and submit again.
    ///
    /// When the client was created with a `turnstileTokenProvider`, its token
    /// is sent as `turnstileToken`; the provider is consulted with the
    /// ``TurnstileAction/featureRequest`` binding (the app key as `cdata`),
    /// so render the widget under that exact action — a feedback-minted token
    /// is rejected here. A Turnstile rejection (HTTP 403) asks the provider
    /// for a fresh token under the same binding and retries exactly once
    /// before throwing.
    public func submitFeatureRequest(
        _ draft: FeatureRequestDraft,
        userToken: String
    ) async throws -> FeatureRequestSubmissionResult {
        let data = try await sendWithTurnstileRetry(
            accepted: [200, 201],
            challenge: .featureRequest(appKey: configuration.appKey)
        ) { token, requestID in
            var request = URLRequest(url: self.configuration.baseURL.appending(path: "/api/v1/feature-requests"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            self.applyCorrelationHeaders(userToken: userToken, requestID: requestID, to: &request)
            await self.applyBearerToken(to: &request)
            request.httpBody = try self.encodedIntakeBody(FeatureRequestSubmitPayload(
                appKey: self.configuration.appKey,
                title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                description: draft.description.trimmingCharacters(in: .whitespacesAndNewlines),
                requesterName: draft.requesterName.nilIfEmpty,
                requesterToken: userToken,
                turnstileToken: token
            ))
            return request
        }
        return try decoder.decode(FeatureRequestSubmissionResult.self, from: data)
    }

    // MARK: - Voting

    /// Sends a vote request with the specified HTTP method (`POST` to cast, `DELETE` to remove).
    private func sendVoteRequest(
        method: String,
        featureRequestId: String,
        userToken: String,
        shipNotifyEmail: String? = nil,
        turnstileToken: String? = nil
    ) async throws -> VoteResult {
        let trimmedID = featureRequestId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw FeedbackClientError.invalidResponse
        }
        let normalizedShipNotifyEmail = shipNotifyEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let normalizedTurnstileToken = turnstileToken?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        if method == "POST" {
            let data = try await sendWithTurnstileRetry(
                accepted: [200],
                challenge: .vote(appKey: configuration.appKey),
                initialToken: normalizedTurnstileToken
            ) { token, requestID in
                let payload = VotePayload(
                    appKey: self.configuration.appKey,
                    userToken: userToken,
                    shipNotifyEmail: normalizedShipNotifyEmail,
                    turnstileToken: token
                )
                var request = URLRequest(
                    url: self.configuration.baseURL.appending(path: "/api/v1/feature-requests/\(trimmedID)/vote")
                )
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                self.applyCorrelationHeaders(userToken: userToken, requestID: requestID, to: &request)
                await self.applyBearerToken(to: &request)
                request.httpBody = try self.encoder.encode(payload)
                return request
            }
            return try decoder.decode(VoteResult.self, from: data)
        } else {
            let payload = VotePayload(
                appKey: configuration.appKey,
                userToken: userToken,
                shipNotifyEmail: nil,
                turnstileToken: nil
            )

            var request = URLRequest(
                url: configuration.baseURL.appending(path: "/api/v1/feature-requests/\(trimmedID)/vote")
            )
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            applyCorrelationHeaders(userToken: userToken, requestID: nextRequestID(), to: &request)
            await applyBearerToken(to: &request)
            request.httpBody = try encoder.encode(payload)

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw FeedbackClientError.invalidResponse
            }
            try validateResponse(httpResponse, data: data, accepted: [200], mapsPermissionErrors: true)
            return try decoder.decode(VoteResult.self, from: data)
        }
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
    /// When human verification is enabled on the server, anonymous voters
    /// on apps with ``PublicAppConfig/requireAnonymousVoteTurnstile`` or voters
    /// providing `shipNotifyEmail` should supply a Turnstile token via
    /// `turnstileToken`. When omitted and the client is configured with a
    /// `turnstileTokenProvider`, a token bound to ``TurnstileAction/vote`` is
    /// requested automatically.
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
    ///   - featureRequestId: Id of the request to vote on.
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
    /// - Throws: ``FeedbackClientError/rateLimited`` on HTTP 429,
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
    ///   - featureRequestId: Id of the request to unvote.
    ///   - userToken: A stable UUID string identifying this user.
    /// - Returns: The new vote state (`voted: false`) and authoritative vote count.
    /// - Throws: ``FeedbackClientError/rateLimited`` on HTTP 429,
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
