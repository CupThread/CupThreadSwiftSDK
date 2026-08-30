import Foundation
import SwiftUI

/// Helper for retrieving localized strings from the SDK's bundle with format arguments.
enum CupThreadStrings {
    static func tr(_ key: String, _ args: CVarArg...) -> String {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: BundleToken.self)
        #endif
        let format = bundle.localizedString(forKey: key, value: key, table: nil)
        if args.isEmpty {
            return format
        }
        return String(format: format, locale: Locale.current, arguments: args)
    }

    static func key(_ key: String) -> LocalizedStringKey {
        LocalizedStringKey(key)
    }
}

#if !SWIFT_PACKAGE
private final class BundleToken {}
#endif
