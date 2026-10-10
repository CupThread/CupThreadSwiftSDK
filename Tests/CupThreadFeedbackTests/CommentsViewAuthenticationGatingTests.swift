import Foundation
import SwiftUI
import Testing
@testable import CupThreadFeedback

/// `CommentsView` must gate its interactive affordances on the *resolved*
/// authenticated access, not provider presence (BUG-24, mirroring #297 for
/// the comment surface): hosts normally install their provider
/// unconditionally, so `supportsAuthentication` is `true` even while the user
/// is signed out — a composer gated on it can only end in a server-rejected
/// submission after the user has written their comment.
@Suite("CommentsView authentication gating")
struct CommentsViewAuthenticationGatingTests {
    private func makeView(
        authenticationProvider: (@Sendable () async -> String?)? = nil,
        preResolvedAuthentication: Bool = false
    ) -> CommentsView {
        CommentsView(
            client: makeClient(authenticationProvider: authenticationProvider),
            userToken: "token_123",
            featureRequestId: "fr_123",
            featureRequestTitle: "Title",
            preResolvedAuthentication: preResolvedAuthentication
        )
    }

    private func makeVisibleComment() -> FeatureRequestComment {
        FeatureRequestComment(
            id: "c-auth-1",
            featureRequestId: "fr_123",
            authorName: "Ada",
            body: "Hello",
            isHidden: false,
            createdAt: "2026-01-01T00:00:00.000Z"
        )
    }

    // MARK: - Provider presence vs. resolved access on the comments surface

    @Test func installedProviderReturningNilResolvesToNoAccess() async {
        let client = makeClient(authenticationProvider: { nil })
        // Provider presence alone — the legacy flag — is not access.
        #expect(client.supportsAuthentication)
        #expect(await client.resolveAuthenticatedAccess() == false)
    }

    @Test func installedProviderReturningTokenResolvesToAccess() async {
        let client = makeClient(authenticationProvider: { "signed-in-jwt" })
        #expect(client.supportsAuthentication)
        #expect(await client.resolveAuthenticatedAccess())
    }

    @Test func clientWithoutProviderResolvesToNoAccess() async {
        let client = makeClient()
        #expect(!client.supportsAuthentication)
        #expect(await client.resolveAuthenticatedAccess() == false)
    }

    // MARK: - Compose footer decision table (BUG-24)

    @Test func composeFooterShowsSignedOutNoticeForUnresolvedAccess() {
        // The fail-closed initial state: an undecided verdict — including a
        // signed-out user of an installed provider — never opens the composer.
        #expect(
            CommentsView.composeAreaPresentation(isCommentsUnavailable: false, isAuthenticated: false)
                == .signInRequired
        )
    }

    @Test func composeFooterShowsComposerForResolvedAccess() {
        #expect(
            CommentsView.composeAreaPresentation(isCommentsUnavailable: false, isAuthenticated: true)
                == .composer
        )
    }

    @Test func composeFooterHidesForUnavailableThreadRegardlessOfAccess() {
        #expect(
            CommentsView.composeAreaPresentation(isCommentsUnavailable: true, isAuthenticated: true)
                == .unavailable
        )
        #expect(
            CommentsView.composeAreaPresentation(isCommentsUnavailable: true, isAuthenticated: false)
                == .unavailable
        )
    }

    // MARK: - Reply-button decision table (BUG-24)

    @Test func replyButtonFollowsResolvedAccessNotProviderPresence() {
        let display = makeVisibleComment().displayModel
        #expect(display.canReply)
        // Signed out: hidden, even though the provider is installed.
        #expect(!CommentsView.showsReplyButton(canReply: display.canReply, isAuthenticated: false))
        // Signed in: offered.
        #expect(CommentsView.showsReplyButton(canReply: display.canReply, isAuthenticated: true))
    }

    @Test func moderatedCommentNeverOffersReplyButton() {
        let moderated = FeatureRequestComment(
            id: "c-auth-moderated",
            featureRequestId: "fr_123",
            authorName: "RudeUser",
            body: "Violating content",
            isHidden: true,
            createdAt: "2026-01-01T00:00:00.000Z"
        )
        let display = moderated.displayModel
        #expect(!display.canReply)
        #expect(!CommentsView.showsReplyButton(canReply: display.canReply, isAuthenticated: true))
    }

    // MARK: - View-level rendering (fail-closed default)

    @MainActor
    @Test func signedOutClientPresentsSignInRequiredFooterDespiteInstalledProvider() {
        // The regression shape from the issue: the provider is installed (the
        // legacy flag is true) but the session resolves to signed out, so the
        // footer must stay the signed-out notice, never the composer.
        let view = makeView(authenticationProvider: { nil })
        #expect(view.client.supportsAuthentication)
        #expect(view.composePresentation == .signInRequired)
        _ = view.body
        _ = view.commentRow(makeVisibleComment())
    }

    @MainActor
    @Test func resolvedAccessPresentsComposerAndReplyRow() {
        let view = makeView(
            authenticationProvider: { "signed-in-jwt" },
            preResolvedAuthentication: true
        )
        #expect(view.composePresentation == .composer)
        _ = view.body
        _ = view.commentRow(makeVisibleComment())
    }
}
