import Foundation
import Testing
@testable import CupThreadFeedback

@Suite("Localization")
struct LocalizationTests {
    private static let targetLanguages = [
        "en",
        "zh-Hans",
        "zh-Hant",
        "zh-HK",
        "zh-TW",
        "ja",
        "fr",
        "es",
        "de",
        "de-CH",
        "it",
        "pt",
        "ko",
        "pl",
        "nb",
        "no",
        "tr",
        "vi",
        "da"
    ]

    private func loadStrings(for language: String) throws -> [String: String] {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: BundleToken.self)
        #endif

        let stringsURL = try #require(
            bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language),
            "Missing Localizable.strings for \(language)"
        )
        let data = try Data(contentsOf: stringsURL)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let dict = try #require(plist as? [String: String], "Failed to parse strings plist for \(language)")
        return dict
    }

    @Test func allTargetLanguageLprojsExist() throws {
        for lang in Self.targetLanguages {
            let dict = try loadStrings(for: lang)
            #expect(!dict.isEmpty, "Language \(lang) should have localized strings")
        }
    }

    @Test func allTargetLanguagesHaveCompleteKeysMatchingEnglish() throws {
        let enDict = try loadStrings(for: "en")
        let enKeys = Set(enDict.keys)
        #expect(enKeys.count == 146, "Expected 146 keys in en.lproj, found \(enKeys.count)")

        for lang in Self.targetLanguages where lang != "en" {
            let dict = try loadStrings(for: lang)
            let langKeys = Set(dict.keys)
            let missing = enKeys.subtracting(langKeys)
            let extra = langKeys.subtracting(enKeys)

            #expect(missing.isEmpty, "\(lang) is missing keys: \(missing)")
            #expect(extra.isEmpty, "\(lang) has extra keys: \(extra)")
            #expect(langKeys.count == enKeys.count, "\(lang) key count does not match en")
        }
    }

    @Test func trResolvesStringsThroughModuleBundle() {
        let resolved = CupThreadStrings.tr("cupthread.features.title")
        #expect(!resolved.isEmpty)
        #expect(
            resolved != "cupthread.features.title",
            "tr() fell back to the raw key — Bundle.module did not resolve to a bundle carrying Localizable.strings"
        )
    }

    @Test func trAppliesFormatArguments() {
        let resolved = CupThreadStrings.tr("cupthread.features.released_in", "1.2.3")
        #expect(resolved.contains("1.2.3"), "Format argument was not applied: \(resolved)")
        #expect(!resolved.contains("%@"), "Format specifier leaked into output: \(resolved)")
    }

    @Test func formatSpecifiersMatchEnglish() throws {
        let enDict = try loadStrings(for: "en")
        let regex = try NSRegularExpression(pattern: "%[0-9]*[a-zA-Z@]")

        func extractSpecifiers(_ str: String) -> [String] {
            let range = NSRange(str.startIndex..<str.endIndex, in: str)
            return regex.matches(in: str, range: range).compactMap {
                Range($0.range, in: str).map { String(str[$0]) }
            }
        }

        for lang in Self.targetLanguages where lang != "en" {
            let dict = try loadStrings(for: lang)
            for (key, enVal) in enDict {
                guard let langVal = dict[key] else { continue }
                let enSpecs = extractSpecifiers(enVal)
                let langSpecs = extractSpecifiers(langVal)
                #expect(
                    enSpecs == langSpecs,
                    "Specifier mismatch in \(lang) for key '\(key)': expected \(enSpecs), got \(langSpecs)"
                )
            }
        }
    }
    // MARK: - Plural families

    private static let pluralFamilyBases = [
        "cupthread.roadmap.column_items",
        "cupthread.features.vote_count_accessibility",
        "cupthread.features.vote_add_accessibility",
        "cupthread.features.vote_remove_accessibility"
    ]

    /// Every plural family ships all four category keys in every locale, so
    /// `CupThreadStrings.trPlural` never has to fall back to a bare key
    /// (issue #9).
    @Test func pluralFamiliesShipAllCategoriesInEveryLocale() throws {
        for lang in Self.targetLanguages {
            let strings = try loadStrings(for: lang)
            for base in Self.pluralFamilyBases {
                for category in ["one", "few", "many", "other"] {
                    let key = "\(base).\(category)"
                    let value = try #require(strings[key], "\(lang) is missing \(key)")
                    #expect(value.contains("lld"), "\(key) is missing its count specifier: \(value)")
                }
            }
        }
    }

    /// The vote-count family composes a suffix after the count phrase, so it
    /// must carry the positional argument specifiers in every category.
    @Test func voteCountFamilyKeepsSuffixPlaceholder() throws {
        for lang in Self.targetLanguages {
            let strings = try loadStrings(for: lang)
            for category in ["one", "few", "many", "other"] {
                let value = try #require(
                    strings["cupthread.features.vote_count_accessibility.\(category)"],
                    "\(lang) vote_count family is missing \(category)"
                )
                #expect(value.contains("%2$@"), "\(lang) vote_count \(category) lost the suffix: \(value)")
                #expect(
                    !value.replacingOccurrences(of: "%2$@", with: "").contains("%@"),
                    "\(lang) vote_count \(category) mixes positional and non-positional specifiers: \(value)"
                )
            }
        }
    }

    /// CLDR integer category selection for every shipped language (issue #9).
    @Test func pluralCategorySelectionMatchesCLDR() {
        let oneOnly = ["en", "da", "de", "de-CH", "es", "it", "nb", "no", "pt", "tr"]
        for language in oneOnly {
            #expect(CupThreadStrings.pluralCategory(for: 1, language: language) == "one", "\(language)")
            #expect(CupThreadStrings.pluralCategory(for: 2, language: language) == "other", "\(language)")
            #expect(CupThreadStrings.pluralCategory(for: 0, language: language) == "other", "\(language)")
        }
        // French treats zero as singular.
        #expect(CupThreadStrings.pluralCategory(for: 0, language: "fr") == "one")
        #expect(CupThreadStrings.pluralCategory(for: 1, language: "fr") == "one")
        #expect(CupThreadStrings.pluralCategory(for: 2, language: "fr") == "other")
        // Polish one/few/many.
        #expect(CupThreadStrings.pluralCategory(for: 1, language: "pl") == "one")
        #expect(CupThreadStrings.pluralCategory(for: 2, language: "pl") == "few")
        #expect(CupThreadStrings.pluralCategory(for: 5, language: "pl") == "many")
        #expect(CupThreadStrings.pluralCategory(for: 22, language: "pl") == "few")
        #expect(CupThreadStrings.pluralCategory(for: 112, language: "pl") == "many")
        #expect(CupThreadStrings.pluralCategory(for: 0, language: "pl") == "many")
        // Category-less languages always resolve to other.
        for language in ["zh-Hans", "zh-Hant", "zh-HK", "zh-TW", "ja", "ko", "vi"] {
            #expect(CupThreadStrings.pluralCategory(for: 1, language: language) == "other", "\(language)")
            #expect(CupThreadStrings.pluralCategory(for: 2, language: language) == "other", "\(language)")
        }
        // Unknown languages degrade to other instead of crashing.
        #expect(CupThreadStrings.pluralCategory(for: 1, language: "xx") == "other")
    }

    /// Behavioral check that `trPlural` resolves the family keys end to end.
    /// The exact English assertions only run when the test process runs in
    /// English (CI); otherwise the no-leak assertions still prove resolution.
    @Test func trPluralResolvesLocalizedCategories() {
        let singular = CupThreadStrings.trPlural("cupthread.roadmap.column_items", count: 1)
        let plural = CupThreadStrings.trPlural("cupthread.roadmap.column_items", count: 2)
        for output in [singular, plural] {
            #expect(!output.contains("lld"), "Format specifier leaked: \(output)")
            #expect(!output.contains("column_items"), "Raw key leaked: \(output)")
        }
        #expect(singular != plural, "Category selection did not change the phrase")

        guard Locale.current.language.languageCode?.identifier == "en" else { return }
        #expect(singular == "1 item", "Unexpected singular output: \(singular)")
        #expect(plural == "2 items", "Unexpected plural output: \(plural)")
        #expect(
            CupThreadStrings.trPlural(
                "cupthread.features.vote_count_accessibility", count: 5, ", including yours"
            ) == "5 votes, including yours",
            "Vote count composition rendered wrong"
        )
        #expect(
            CupThreadStrings.trPlural(
                "cupthread.features.vote_count_accessibility", count: 1, ", including yours"
            ) == "1 vote, including yours",
            "Vote count singular composition rendered wrong"
        )
    }
}
