import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Hosted-challenge bridge message policy (issue #566)

/// Pins `TurnstileBridgePolicy`, the inbound trust boundary of the
/// `turnstileBridge` script-message handler: only the challenge page's main
/// frame on the page's origin may post into the bridge (#566). Because
/// `WKScriptMessage` and `WKFrameInfo` cannot be constructed in unit tests,
/// the decision lives in the pure helper pinned here, and the wiring in the
/// sheet's handler is pinned by the source-scan pattern the sibling view
/// tests use.
@Suite("Turnstile bridge message policy")
struct TurnstileBridgePolicyTests {
    private static let challengeURL = URL(string: "https://app.cupthread.com/turnstile/verify")!

    /// `WKSecurityOrigin.port` answers `0` for an implicit default port, so
    /// `0` is the ordinary main-frame spelling of "no explicit port".
    private func accepts(
        isMainFrame: Bool = true,
        originProtocol: String = "https",
        originHost: String = "app.cupthread.com",
        originPort: Int = 0,
        challengeURL: URL = Self.challengeURL
    ) -> Bool {
        TurnstileBridgePolicy.acceptsBridgeMessage(
            isMainFrame: isMainFrame,
            originProtocol: originProtocol,
            originHost: originHost,
            originPort: originPort,
            challengeURL: challengeURL
        )
    }

    // MARK: The legitimate path

    @Test func mainFrameOnTheChallengeOriginIsAccepted() {
        #expect(accepts())
    }

    @Test func protocolAndHostCompareCaseInsensitively() {
        #expect(accepts(originProtocol: "HTTPS", originHost: "APP.CupThread.COM"))
    }

    @Test func explicitPort443IsTheSameOriginAsTheImplicitDefault() {
        #expect(accepts(originPort: 443))
    }

    // MARK: Frame restriction

    @Test func nonMainFrameIsRejectedEvenOnTheChallengeOrigin() {
        #expect(!accepts(isMainFrame: false))
    }

    // MARK: Origin restriction

    @Test func foreignHostIsRejected() {
        #expect(!accepts(originHost: "evil.example.com"))
    }

    @Test func plainHTTPOriginIsRejectedForAnHTTPSChallengePage() {
        #expect(!accepts(originProtocol: "http"))
    }

    @Test func nonDefaultPortIsRejected() {
        #expect(!accepts(originPort: 8080))
        #expect(!accepts(originPort: 444))
    }

    @Test func emptyHostIsRejected() {
        #expect(!accepts(originHost: ""))
    }

    // MARK: The self-hosted/local override keeps its own origin

    @Test func customSchemeAndPortOverrideAcceptsItsOwnOrigin() {
        // `FeedbackClientConfiguration.turnstileChallengeURL` preserves the
        // override's scheme and port for self-hosted and local portals
        // (pinned by `TurnstileChallengePageTests.explicitPortAndSchemeArePreserved`),
        // and the pin is origin equality — so such a page keeps working,
        // while a different port or host on the same override stays foreign.
        let devChallenge = URL(string: "http://127.0.0.1:8765/turnstile/verify")!
        #expect(TurnstileBridgePolicy.acceptsBridgeMessage(
            isMainFrame: true,
            originProtocol: "http",
            originHost: "127.0.0.1",
            originPort: 8765,
            challengeURL: devChallenge
        ))
        #expect(!TurnstileBridgePolicy.acceptsBridgeMessage(
            isMainFrame: true,
            originProtocol: "http",
            originHost: "127.0.0.1",
            originPort: 8766,
            challengeURL: devChallenge
        ))
        #expect(!TurnstileBridgePolicy.acceptsBridgeMessage(
            isMainFrame: true,
            originProtocol: "http",
            originHost: "localhost",
            originPort: 8765,
            challengeURL: devChallenge
        ))
    }

    // MARK: Wiring

    @Test func theSheetHandlerConsultsThePolicyBeforeForwarding() throws {
        // WKScriptMessage cannot be constructed in tests, so the wiring is
        // pinned source-side: the frame/origin policy must be a *condition*
        // of the handler's rejecting guard, evaluated before the payload
        // parse, so an out-of-policy message never reaches `onMessage` (#566).
        let content = try Self.source("TurnstileChallengeSheet.swift")
        let body = try Self.functionBody(named: "func userContentController(", in: content)
        let guardStart = try #require(
            body.range(of: "guard message.name == Self.bridgeName,"),
            "the handler must still gate on the bridge name inside a guard"
        )
        let conditions = body[guardStart.upperBound...]
        let guardElse = try #require(
            conditions.range(of: "else {"),
            "the guard must still reject out-of-policy messages"
        )
        let guardConditions = conditions[..<guardElse.lowerBound]
        let policy = try #require(
            guardConditions.range(of: "TurnstileBridgePolicy.acceptsBridgeMessage("),
            "the frame/origin policy must be a condition of the rejecting guard (#566)"
        )
        let parse = try #require(
            guardConditions.range(of: "TurnstileBridgeMessage.parse(message.body)"),
            "the payload parse must remain a condition of the same guard"
        )
        #expect(
            policy.lowerBound < parse.lowerBound,
            "the frame/origin check must run before the payload parse (#566)"
        )
        // Positive polarity: a negated call in this guard would admit
        // exactly the messages the policy refuses (#566).
        #expect(
            !guardConditions[..<policy.lowerBound].suffix(4).contains("!"),
            "the policy must gate the guard positively, not negated (#566)"
        )
        // The policy must be fed WebKit's own frame metadata, not constants:
        // binding `message.frameInfo` is what makes the guard real (#566).
        for binding in [
            "isMainFrame: message.frameInfo.isMainFrame",
            "originProtocol: message.frameInfo.securityOrigin.protocol",
            "originHost: message.frameInfo.securityOrigin.host",
            "originPort: message.frameInfo.securityOrigin.port",
            "challengeURL: challengeURL"
        ] {
            #expect(
                guardConditions.range(of: binding) != nil,
                "the handler must bind WebKit frame metadata into the policy: \(binding) (#566)"
            )
        }
        #expect(
            conditions[guardElse.upperBound...].contains("onMessage(parsed)"),
            "only a message that passed the guard may reach onMessage (#566)"
        )
    }

    // MARK: Fixtures

    /// Reads an SDK source file relative to this test file, walking up to the
    /// package root (Swift Testing `#filePath` lands deep in DerivedData).
    private static func source(_ name: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            directory.deleteLastPathComponent()
            let candidate = directory
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("CupThreadFeedback", isDirectory: true)
                .appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }

    /// The body of the first function whose declaration starts with `marker`,
    /// located by brace matching so the scan stays inside the intended
    /// function even when sibling functions contain similar statements.
    private static func functionBody(named marker: String, in content: String) throws -> Substring {
        let start = try #require(
            content.range(of: marker),
            "the \(marker) anchor was renamed; update this scan"
        )
        let remainder = content[start.upperBound...]
        var depth = 0
        var started = false
        var index = remainder.startIndex
        while index < remainder.endIndex {
            let character = remainder[index]
            if character == "{" {
                depth += 1
                started = true
            } else if character == "}" {
                depth -= 1
                if started && depth == 0 {
                    return remainder[..<index]
                }
            }
            index = remainder.index(after: index)
        }
        return remainder
    }
}
