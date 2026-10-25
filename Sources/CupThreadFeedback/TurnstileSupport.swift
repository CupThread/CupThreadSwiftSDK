import Foundation

// MARK: - Turnstile-gated intake (#53, Phase 1)

extension FeedbackClient {
    /// Whether this client can present a Turnstile token — i.e. it was
    /// created with a `turnstileTokenProvider`.
    var canPresentTurnstileToken: Bool { turnstileTokenProvider != nil }

    /// Resolves a Turnstile token from the configured provider for the given
    /// widget binding, trimming empty results to `nil`.
    func resolvedTurnstileToken(for challenge: TurnstileChallenge) async -> String? {
        guard let provider = turnstileTokenProvider else { return nil }
        return (await provider(challenge))?.nilIfEmpty
    }

    /// Sends a Turnstile-gated intake request, retrying exactly once with a
    /// freshly provided token when the server's human-verification gate
    /// rejects the first attempt (HTTP 403) and a provider is configured.
    ///
    /// - Parameters:
    ///   - accepted: Status codes that mean success for the endpoint.
    ///   - challenge: The widget binding the endpoint validates — consulted
    ///     tokens are minted (or rendered) for this exact `(action, cdata)`
    ///     pair, and the retry asks for the same binding again.
    ///   - initialToken: Optional caller-supplied explicit Turnstile token to
    ///     use on the first attempt. When present, the configured token provider
    ///     is not consulted prior to the initial request; if the server
    ///     subsequently rejects the attempt, the provider is consulted for a
    ///     fresh retry token.
    ///   - mapResourceNotFound: Forwarded to `validateResponse` so endpoints
    ///     with a meaningful missing-resource state (votes on a deleted
    ///     feature request, API-27) can map envelope-carrying `404`s to
    ///     their typed error.
    ///   - makeRequest: Builds the request for a `(turnstileToken, requestID)`
    ///     pair — called once per attempt so the retry re-encodes the payload
    ///     with the fresh token and a new correlation id.
    /// - Returns: The validated response body of the successful attempt.
    /// - Throws: ``FeedbackClientError/turnstileRequired(message:requestId:)``
    ///   when no provider is configured, the provider yields no fresh token
    ///   for the retry, or the retried attempt is rejected again; otherwise
    ///   the endpoint's usual errors.
    func sendWithTurnstileRetry(
        accepted: Set<Int>,
        challenge: TurnstileChallenge,
        initialToken: String? = nil,
        mapResourceNotFound: ((String, String?) -> FeedbackClientError)? = nil,
        makeRequest: (String?, String) async throws -> URLRequest
    ) async throws -> Data {
        let firstToken: String?
        if let explicit = initialToken?.nilIfEmpty {
            firstToken = explicit
        } else {
            firstToken = await resolvedTurnstileToken(for: challenge)
        }
        do {
            return try await sendTurnstileAttempt(
                accepted: accepted,
                turnstileToken: firstToken,
                mapResourceNotFound: mapResourceNotFound,
                makeRequest: makeRequest
            )
        } catch let error as FeedbackClientError {
            guard case .turnstileRequired = error, canPresentTurnstileToken else {
                throw error
            }
            // The gate rejected the first attempt and a token provider is
            // configured: mint a fresh token bound to the same action and
            // retry exactly once.
            guard let retryToken = await resolvedTurnstileToken(for: challenge) else {
                throw error
            }
            return try await sendTurnstileAttempt(
                accepted: accepted,
                turnstileToken: retryToken,
                mapResourceNotFound: mapResourceNotFound,
                makeRequest: makeRequest
            )
        }
    }

    private func sendTurnstileAttempt(
        accepted: Set<Int>,
        turnstileToken: String?,
        mapResourceNotFound: ((String, String?) -> FeedbackClientError)? = nil,
        makeRequest: (String?, String) async throws -> URLRequest
    ) async throws -> Data {
        let request = try await makeRequest(turnstileToken, nextRequestID())
        let (data, response) = try await session.data(for: request, delegate: SameOriginRedirectLimiter())
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }
        // Every Turnstile-gated endpoint is an anonymous intake endpoint, so
        // console-permission rejections (401/403) map to their typed errors;
        // Turnstile-shaped 403s are handled earlier by `typedError`.
        try validateResponse(
            httpResponse,
            data: data,
            accepted: accepted,
            mapsPermissionErrors: true,
            mapResourceNotFound: mapResourceNotFound
        )
        return data
    }

    /// Whether a rejection body represents the server's Turnstile
    /// human-verification gate. The machine-readable `code` wins when
    /// present — `turnstile_required` (no token presented) and
    /// `turnstile_verification_failed` (siteverify rejected the token) — and
    /// `turnstile_not_configured` deliberately stays out (no client token can
    /// pass a deployment without a secret). Releases from before SaaS #1052
    /// carried no code on intake, so the message matches as a fallback.
    static func isTurnstileRejection(code: String?, message: String?) -> Bool {
        if code == "turnstile_required" || code == "turnstile_verification_failed" {
            return true
        }
        guard code == nil else { return false }
        return message?.range(of: "turnstile", options: .caseInsensitive) != nil
            || message?.range(of: "human verification", options: .caseInsensitive) != nil
    }
}
