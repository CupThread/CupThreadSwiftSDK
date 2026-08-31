import Foundation

// MARK: - Private payload types

private struct FeatureRequestSubmitPayload: Encodable, Sendable {
    let appKey: String
    let title: String
    let description: String
    let requesterName: String?
    let requesterToken: String
}

private struct VotePayload: Encodable, Sendable {
    let appKey: String
    let userToken: String
}

// MARK: - FeedbackClient extension

extension FeedbackClient {

    /// Fetches the feature requests list for the configured app.
    ///
    /// Results include each request's vote count and whether the current user
    /// already voted (`hasVoted`), which is why the call requires a
    /// `userToken`.
    /// - Parameters:
    ///   - userToken: A stable UUID string identifying this user (for own pending requests and vote state).
    ///   - limit: Maximum number of results to return.
    ///   - offset: Pagination offset.
    ///   - versionId: Optional version filter (see `fetchVersions()`).
    ///   - query: Optional server-side search over title and description
    ///     (rate-limited per IP and briefly cached by the backend).
    /// - Returns: The matching requests plus the unpaginated `total`.
    /// - Throws: ``FeedbackClientError/unexpectedStatus(code:message:)`` or
    ///   ``FeedbackClientError/invalidResponse``.
    public func fetchFeatureRequests(
        userToken: String,
        limit: Int = 50,
        offset: Int = 0,
        versionId: String? = nil,
        query: String? = nil
    ) async throws -> ListFeatureRequestsResult {
        let base = configuration.baseURL.appending(path: "/api/v1/feature-requests")
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: true) else {
            throw FeedbackClientError.invalidResponse
        }
        var queryItems = [
            URLQueryItem(name: "appKey", value: configuration.appKey),
            URLQueryItem(name: "userToken", value: userToken),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset))
        ]
        if let versionId {
            queryItems.append(URLQueryItem(name: "versionId", value: versionId))
        }
        if let query, !query.isEmpty {
            queryItems.append(URLQueryItem(name: "q", value: query))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw FeedbackClientError.invalidResponse
        }

        let (data, response) = try await session.data(for: URLRequest(url: url))
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }
        if httpResponse.statusCode != 200 {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw FeedbackClientError.unexpectedStatus(code: httpResponse.statusCode, message: message)
        }
        return try decoder.decode(ListFeatureRequestsResult.self, from: data)
    }

    /// Submits a new feature request. It will be pending until approved by an admin.
    ///
    /// Titles and descriptions are trimmed; an empty `requesterName` is sent
    /// as anonymous. The submitting user is recorded via `userToken`, which
    /// is also how the console recognizes "own" requests (those can't be
    /// self-voted).
    /// - Parameters:
    ///   - draft: Title, description, and optional requester name.
    ///   - userToken: A stable UUID string identifying this user.
    /// - Returns: The created request's id and whether it is pending review.
    /// - Throws: ``FeedbackClientError/unexpectedStatus(code:message:)`` or
    ///   ``FeedbackClientError/invalidResponse``.
    public func submitFeatureRequest(
        _ draft: FeatureRequestDraft,
        userToken: String
    ) async throws -> FeatureRequestSubmissionResult {
        let payload = FeatureRequestSubmitPayload(
            appKey: configuration.appKey,
            title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: draft.description.trimmingCharacters(in: .whitespacesAndNewlines),
            requesterName: draft.requesterName.nilIfEmpty,
            requesterToken: userToken
        )

        var request = URLRequest(url: configuration.baseURL.appending(path: "/api/v1/feature-requests"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }
        if httpResponse.statusCode != 200 && httpResponse.statusCode != 201 {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw FeedbackClientError.unexpectedStatus(code: httpResponse.statusCode, message: message)
        }
        return try decoder.decode(FeatureRequestSubmissionResult.self, from: data)
    }

    /// Toggles the current user's vote on a feature request.
    ///
    /// Calling this on a request the user already voted on removes the vote.
    /// ``FeatureRequestsView`` applies the flip optimistically and reconciles
    /// with the returned server state.
    /// - Parameters:
    ///   - featureRequestId: Id of the request to vote on.
    ///   - userToken: A stable UUID string identifying this user.
    /// - Returns: The new vote state and the request's authoritative vote count.
    /// - Throws: ``FeedbackClientError/unexpectedStatus(code:message:)`` or
    ///   ``FeedbackClientError/invalidResponse``.
    public func toggleVote(
        featureRequestId: String,
        userToken: String
    ) async throws -> VoteResult {
        let payload = VotePayload(appKey: configuration.appKey, userToken: userToken)

        var request = URLRequest(
            url: configuration.baseURL.appending(path: "/api/v1/feature-requests/\(featureRequestId)/vote")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }
        if httpResponse.statusCode != 200 {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw FeedbackClientError.unexpectedStatus(code: httpResponse.statusCode, message: message)
        }
        return try decoder.decode(VoteResult.self, from: data)
    }
}

// MARK: - Private helpers

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
