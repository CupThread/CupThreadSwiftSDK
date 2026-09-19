import Foundation

// MARK: - Turnstile-gated intake (#53, Phase 1)

extension FeedbackClient {
    /// Whether this client can present a Turnstile token — i.e. it was
    /// created with a `turnstileTokenProvider`.
    var canPresentTurnstileToken: Bool { turnstileTokenProvider != nil }

    /// Resolves a Turnstile token from the configured provider, trimming
    /// empty results to `nil`.
    func resolvedTurnstileToken() async -> String? {
        guard let provider = turnstileTokenProvider else { return nil }
        return (await provider())?.nilIfEmpty
    }

    /// Sends a Turnstile-gated intake request, retrying exactly once with a
    /// freshly provided token when the server's human-verification gate
    /// rejects the first attempt (HTTP 403) and a provider is configured.
    ///
    /// - Parameters:
    ///   - accepted: Status codes that mean success for the endpoint.
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
        makeRequest: (String?, String) async throws -> URLRequest
    ) async throws -> Data {
        let firstToken = await resolvedTurnstileToken()
        do {
            return try await sendTurnstileAttempt(
                accepted: accepted,
                turnstileToken: firstToken,
                makeRequest: makeRequest
            )
        } catch let error as FeedbackClientError {
            guard case .turnstileRequired = error, canPresentTurnstileToken else {
                throw error
            }
            // The gate rejected the first attempt and a token provider is
            // configured: mint a fresh token and retry exactly once.
            guard let retryToken = await resolvedTurnstileToken() else {
                throw error
            }
            return try await sendTurnstileAttempt(
                accepted: accepted,
                turnstileToken: retryToken,
                makeRequest: makeRequest
            )
        }
    }

    private func sendTurnstileAttempt(
        accepted: Set<Int>,
        turnstileToken: String?,
        makeRequest: (String?, String) async throws -> URLRequest
    ) async throws -> Data {
        let request = try await makeRequest(turnstileToken, nextRequestID())
        let (data, response) = try await session.data(for: request)
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
            mapsPermissionErrors: true
        )
        return data
    }

    /// Whether a rejection body represents the server's Turnstile
    /// human-verification gate. The machine-readable `code` wins when
    /// present — `turnstile_verification_failed` (the uploads-sessions route,
    /// already live) and `turnstile_required` (the intake endpoints, Phase 0)
    /// — falling back to the human-readable message until the intake
    /// endpoints ship their code.
    static func isTurnstileRejection(code: String?, message: String?) -> Bool {
        if code == "turnstile_required" || code == "turnstile_verification_failed" {
            return true
        }
        guard code == nil else { return false }
        return message?.range(of: "turnstile", options: .caseInsensitive) != nil
            || message?.range(of: "human verification", options: .caseInsensitive) != nil
    }
}
