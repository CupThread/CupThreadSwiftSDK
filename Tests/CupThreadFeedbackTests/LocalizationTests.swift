import Foundation
import Testing
@testable import CupThreadFeedback

@Suite("Localization")
struct LocalizationTests {
    private static let targetLanguages = [
        "en",
        "zh-Hans",
        "zh-Hant",
        "ja",
        "fr",
        "es",
        "de",
        "it",
        "pt",
        "ko",
        "pl",
        "nb",
        "no",
        "tr",
        "vi"
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
        #expect(enKeys.count == 79, "Expected 79 keys in en.lproj, found \(enKeys.count)")

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
}
