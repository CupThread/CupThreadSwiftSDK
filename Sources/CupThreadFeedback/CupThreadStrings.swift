import Foundation
import SwiftUI

/// Helper for retrieving localized strings from the SDK's bundle with format arguments.
enum CupThreadStrings {
    static func tr(_ key: String, _ args: CVarArg...) -> String {
        let bundle = sdkBundle
        let format = bundle.localizedString(forKey: key, value: key, table: nil)
        if args.isEmpty {
            return format
        }
        return String(format: format, locale: Locale.current, arguments: args)
    }

    /// Retrieves a localized count string through a plural family: the lookup
    /// key is `"\(key).\(category)"` with `.other` as the fallback (issue #9).
    /// Families ship all four categories in every locale; `count` is always
    /// format argument #1, `argument` (when present) is #2.
    static func trPlural(_ key: String, count: Int64, _ argument: CVarArg? = nil) -> String {
        let bundle = sdkBundle
        let language = bundle.preferredLocalizations.first ?? "en"
        let category = pluralCategory(for: count, language: language)
        var format = bundle.localizedString(forKey: "\(key).\(category)", value: "", table: nil)
        if format.isEmpty {
            format = bundle.localizedString(forKey: "\(key).other", value: "", table: nil)
        }
        if format.isEmpty {
            return key
        }
        var arguments: [CVarArg] = [count]
        if let argument {
            arguments.append(argument)
        }
        return String(format: format, locale: Locale.current, arguments: arguments)
    }

    /// CLDR integer plural category for the languages the SDK ships. Locales
    /// without number-based categories (CJK, Vietnamese) and unknown locales
    /// always resolve to `other`.
    static func pluralCategory(for count: Int64, language: String) -> String {
        switch language {
        case "fr":
            return (0...1).contains(count) ? "one" : "other"
        case "pl":
            if count == 1 { return "one" }
            let lastDigit = count % 10, lastTwo = count % 100
            if (2...4).contains(lastDigit) && !(12...14).contains(lastTwo) { return "few" }
            return "many"
        case "en", "da", "de", "de-CH", "es", "it", "nb", "no", "pt", "tr":
            return count == 1 ? "one" : "other"
        default:
            return "other"
        }
    }

    /// Assembled column accessibility label: "<column>, <count phrase>".
    /// The count phrase resolves through the plural family; the connector and
    /// word order stay under each locale's control.
    static func columnAccessibilityLabel(name: String, count: Int) -> String {
        tr(
            "cupthread.roadmap.column_accessibility", name,
            trPlural("cupthread.roadmap.column_items", count: Int64(count))
        )
    }

    private static var sdkBundle: Bundle {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return Bundle(for: BundleToken.self)
        #endif
    }

    static func key(_ key: String) -> LocalizedStringKey {
        LocalizedStringKey(key)
    }
}

#if !SWIFT_PACKAGE
private final class BundleToken {}
#endif
