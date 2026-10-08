import Foundation
import SwiftUI
import Testing
@testable import CupThreadFeedback

// MARK: - Policy Validation

@Suite("WebURLPolicyValidation")
struct WebURLPolicyValidationTests {
    @Test func isAllowedWebURLAcceptsValidHttpAndHttpsURLs() throws {
        let allowedURLs = [
            "https://example.com",
            "http://example.com",
            "https://sub.domain.org/path?key=value#hash",
            "http://localhost:8080/api",
            "HTTPS://EXAMPLE.COM/UPPERCASE"
        ]

        for urlString in allowedURLs {
            let url = try #require(URL(string: urlString))
            #expect(isAllowedWebURL(url) == true, "Expected \(urlString) to be allowed")
        }
    }

    @Test func isAllowedWebURLRejectsDisallowedSchemes() throws {
        let disallowedURLs = [
            "tel:1234567890",
            "tel://1234567890",
            "javascript:alert(1)",
            "shortcuts://run-shortcut",
            "myapp://open-view",
            "mailto:user@example.com",
            "file:///etc/passwd",
            "data:text/html,<b>hi</b>",
            "ftp://ftp.example.com",
            "sms:123456"
        ]

        for urlString in disallowedURLs {
            let url = try #require(URL(string: urlString))
            #expect(isAllowedWebURL(url) == false, "Expected \(urlString) to be rejected")
        }
    }

    @Test func isAllowedWebURLRejectsMissingOrEmptyHost() {
        let invalidURLs = [
            "https://",
            "http://",
            "http:///only-path",
            "//example.com"
        ]

        for urlString in invalidURLs {
            if let url = URL(string: urlString) {
                #expect(isAllowedWebURL(url) == false, "Expected \(urlString) to be rejected")
            }
        }
    }
}

// MARK: - Website URL Normalization

@Suite("WebsiteURLNormalization")
struct WebsiteURLNormalizationTests {
    @Test func normalizeWebsiteURLPrefixesHttpsForBareHost() {
        #expect(normalizeWebsiteURL("example.com") == URL(string: "https://example.com"))
        #expect(normalizeWebsiteURL("example.com/profile") == URL(string: "https://example.com/profile"))
        #expect(normalizeWebsiteURL("sub.example.co.uk") == URL(string: "https://sub.example.co.uk"))
        #expect(normalizeWebsiteURL("   example.com   ") == URL(string: "https://example.com"))
    }

    @Test func normalizeWebsiteURLPreservesExistingHttpAndHttps() {
        #expect(normalizeWebsiteURL("https://example.com") == URL(string: "https://example.com"))
        #expect(normalizeWebsiteURL("http://example.com/blog") == URL(string: "http://example.com/blog"))
        #expect(normalizeWebsiteURL("https://example.com:8443") == URL(string: "https://example.com:8443"))
    }

    @Test func normalizeWebsiteURLRejectsDisallowedSchemes() {
        let disallowed = [
            "tel:1234567890",
            "javascript:alert(1)",
            "shortcuts://run-my-shortcut",
            "myapp://deep-link",
            "mailto:test@example.com",
            "file:///etc/shadow",
            "data:text/plain,hello",
            "ftp://ftp.test.org"
        ]

        for item in disallowed {
            #expect(normalizeWebsiteURL(item) == nil, "Expected \(item) to normalize to nil")
        }
    }

    @Test func normalizeWebsiteURLRejectsInvalidOrEmptyStrings() {
        #expect(normalizeWebsiteURL("") == nil)
        #expect(normalizeWebsiteURL("   ") == nil)
        #expect(normalizeWebsiteURL("https://") == nil)
        #expect(normalizeWebsiteURL("http://") == nil)
    }
}

// MARK: - Markdown Attributed String Sanitization

@Suite("MarkdownTextSanitization")
struct MarkdownTextSanitizationTests {
    @Test func markdownContainingDisallowedSchemesProducesNoOpenableLink() {
        let disallowedMarkdownSamples = [
            "[Call us](tel:1234567890)",
            "[Execute](javascript:alert(1))",
            "[Run Shortcut](shortcuts://run)",
            "[Open App](myapp://home)",
            "[Local File](file:///secret.txt)",
            "[Send Mail](mailto:support@example.com)"
        ]

        for sample in disallowedMarkdownSamples {
            let attributed = MarkdownText.attributed(sample)
            for run in attributed.runs {
                #expect(run.link == nil, "Expected no link attribute for: \(sample), but found \(String(describing: run.link))")
            }
        }
    }

    @Test func httpsAndHttpWebLinksRemainOpenable() {
        let httpsAttributed = MarkdownText.attributed("[Visit Website](https://example.com)")
        var foundHttpsLink = false
        for run in httpsAttributed.runs {
            if let link = run.link {
                #expect(link == URL(string: "https://example.com"))
                #expect(isAllowedWebURL(link) == true)
                foundHttpsLink = true
            }
        }
        #expect(foundHttpsLink == true)

        let httpAttributed = MarkdownText.attributed("[Read Docs](http://docs.example.org/guide)")
        var foundHttpLink = false
        for run in httpAttributed.runs {
            if let link = run.link {
                #expect(link == URL(string: "http://docs.example.org/guide"))
                #expect(isAllowedWebURL(link) == true)
                foundHttpLink = true
            }
        }
        #expect(foundHttpLink == true)
    }

    @Test func mixedContentNeutralizesOnlyDisallowedLinks() {
        let mixed = "[Safe Link](https://example.com) then [Phone Link](tel:5551234567) and [Another Safe](https://cupthread.com)"
        let attributed = MarkdownText.attributed(mixed)

        var safeLinks: [URL] = []
        for run in attributed.runs {
            if let link = run.link {
                safeLinks.append(link)
            }
        }

        #expect(safeLinks == [
            URL(string: "https://example.com")!,
            URL(string: "https://cupthread.com")!
        ])
    }
}

// MARK: - Remote Image URL Validation

@Suite("RemoteImageURLValidation")
struct RemoteImageURLValidationTests {
    @Test func remoteImageURLAcceptsValidHttpsURLs() throws {
        let valid = [
            "https://cdn.example.com/avatar.png",
            "https://sub.domain.org/path/icon.webp?size=small#hash",
            "  https://cdn.example.com/trimmed.png  ",
            "https://images.example.com:8443/user/123.jpg"
        ]

        for item in valid {
            let url = try #require(remoteImageURL(from: item), "Expected \(item) to be accepted")
            #expect(url.scheme == "https")
            #expect(isAllowedSecureImageURL(url) == true)
        }
    }

    @Test func remoteImageURLRejectsNonHttpsAndDisallowedSchemes() {
        let disallowed = [
            "http://images.example.org/user/123.jpg",
            "http://example.com/avatar.png",
            "http://localhost:3000/avatar.png",
            "file:///etc/passwd",
            "file:///Users/lex/avatar.png",
            "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY44YAAAAASUVORK5CYII=",
            "javascript:alert(1)",
            "shortcuts://run-shortcut",
            "myapp://open-view",
            "tel:1234567890",
            "mailto:user@example.com",
            "ftp://ftp.example.com/avatar.png",
            "sms:123456"
        ]

        for item in disallowed {
            #expect(remoteImageURL(from: item) == nil, "Expected \(item) to be rejected by remoteImageURL")
        }
    }

    @Test func remoteImageURLRejectsNilEmptyWhitespaceAndMissingHost() {
        #expect(remoteImageURL(from: nil) == nil)
        #expect(remoteImageURL(from: "") == nil)
        #expect(remoteImageURL(from: "   ") == nil)
        #expect(remoteImageURL(from: "https://") == nil)
        #expect(remoteImageURL(from: "http://") == nil)
        #expect(remoteImageURL(from: "example.com/avatar.png") == nil)
        #expect(remoteImageURL(from: "//example.com/avatar.png") == nil)
    }

    @Test func avatarViewResolvedURLFallsBackToNilForNonHttpsOrDisallowedSchemes() {
        let httpAvatar = AvatarView(url: "http://insecure.example.com/avatar.png")
        #expect(httpAvatar.resolvedURL == nil, "Non-HTTPS URL must resolve to nil and fall back to placeholder")

        let maliciousAvatar = AvatarView(url: "file:///etc/passwd")
        #expect(maliciousAvatar.resolvedURL == nil)

        let dataAvatar = AvatarView(url: "data:image/png;base64,abc")
        #expect(dataAvatar.resolvedURL == nil)

        let scriptAvatar = AvatarView(url: "javascript:alert(1)")
        #expect(scriptAvatar.resolvedURL == nil)

        let safeAvatar = AvatarView(url: "https://cdn.example.com/user.png")
        #expect(safeAvatar.resolvedURL == URL(string: "https://cdn.example.com/user.png"))

        let nilAvatar = AvatarView(url: nil)
        #expect(nilAvatar.resolvedURL == nil)

        let emptyAvatar = AvatarView(url: "   ")
        #expect(emptyAvatar.resolvedURL == nil)
    }
}

// MARK: - Download Host Validation (SEC-8)

@Suite("DownloadHostValidation")
struct DownloadHostValidationTests {
    @Test func isAllowedDownloadHostAcceptsExactAndSameRegistrableHosts() {
        // Exact match, including case and surrounding whitespace normalization
        #expect(isAllowedDownloadHost("api.cupthread.com", baseHost: "api.cupthread.com"))
        #expect(isAllowedDownloadHost("API.CupThread.COM", baseHost: "api.cupthread.com"))
        #expect(isAllowedDownloadHost("  api.cupthread.com  ", baseHost: "api.cupthread.com"))

        // Sibling subdomains and the apex of the same registrable domain
        #expect(isAllowedDownloadHost("cdn.cupthread.com", baseHost: "api.cupthread.com"))
        #expect(isAllowedDownloadHost("downloads.cdn.cupthread.com", baseHost: "api.cupthread.com"))
        #expect(isAllowedDownloadHost("cupthread.com", baseHost: "api.cupthread.com"))
        #expect(isAllowedDownloadHost("api.cupthread.com", baseHost: "cupthread.com"))

        // Apex ↔ subdomain under a second-level public suffix
        #expect(isAllowedDownloadHost("downloads.example.co.uk", baseHost: "api.example.co.uk"))
        #expect(isAllowedDownloadHost("example.co.uk", baseHost: "downloads.example.co.uk"))

        // Trailing-dot FQDN spelling normalizes away
        #expect(isAllowedDownloadHost("cdn.cupthread.com.", baseHost: "api.cupthread.com"))
    }

    @Test func isAllowedDownloadHostRejectsPublicSuffixAndMultiTenantSiblings() {
        // A bare TLD is never an allowed parent of the base host (SEC-8 "com" case)
        #expect(isAllowedDownloadHost("com", baseHost: "api.cupthread.com") == false)
        #expect(isAllowedDownloadHost("com", baseHost: "cupthread.com") == false)

        // Hosts under a shared public suffix have no shared operator
        #expect(isAllowedDownloadHost("attacker.co.uk", baseHost: "api.example.co.uk") == false)
        #expect(isAllowedDownloadHost("co.uk", baseHost: "api.example.co.uk") == false)
        #expect(isAllowedDownloadHost("evil.example.co.uk", baseHost: "api.other.co.uk") == false)

        // Multi-tenant hosting suffixes behave the same way
        #expect(isAllowedDownloadHost("evil.github.io", baseHost: "org.github.io") == false)
        #expect(isAllowedDownloadHost("github.io", baseHost: "org.github.io") == false)
        #expect(isAllowedDownloadHost("evil.herokuapp.com", baseHost: "org.herokuapp.com") == false)

        // Unrelated hosts keep failing closed
        #expect(isAllowedDownloadHost("evil.example", baseHost: "api.cupthread.com") == false)
        #expect(isAllowedDownloadHost("notcupthread.com", baseHost: "cupthread.com") == false)
        #expect(isAllowedDownloadHost("evilcupthread.com", baseHost: "api.cupthread.com") == false)
        #expect(isAllowedDownloadHost("api.cupthread.com.evil.com", baseHost: "api.cupthread.com") == false)
    }

    @Test func isAllowedDownloadHostFailsClosedForDegenerateHosts() {
        // IP-literal base hosts establish no registrable-domain relationship
        #expect(isAllowedDownloadHost("203.0.113.10", baseHost: "203.0.113.5") == false)
        #expect(isAllowedDownloadHost("evil.example", baseHost: "203.0.113.5") == false)

        // Empty and whitespace hosts are rejected outright
        #expect(isAllowedDownloadHost("", baseHost: "api.cupthread.com") == false)
        #expect(isAllowedDownloadHost("cdn.cupthread.com", baseHost: "") == false)
        #expect(isAllowedDownloadHost("   ", baseHost: "api.cupthread.com") == false)

        // Single-label bases never accept a different host
        #expect(isAllowedDownloadHost("evil.localhost", baseHost: "localhost") == false)
        #expect(isAllowedDownloadHost("localhost", baseHost: "localhost"))
    }
}
