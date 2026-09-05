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
