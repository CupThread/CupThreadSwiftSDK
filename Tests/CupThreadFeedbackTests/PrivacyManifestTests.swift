import Foundation
import Testing
@testable import CupThreadFeedback

/// Guards the shipped privacy manifest (`PrivacyInfo.xcprivacy`): hosts and
/// App Store review rely on these declarations being present and accurate,
/// so any drift from the audited contract fails the suite.
@Suite("Privacy Manifest")
struct PrivacyManifestTests {
    private final class BundleToken {}

    private static let expectedCollectedDataTypes: Set<String> = [
        "NSPrivacyCollectedDataTypeUserID",
        "NSPrivacyCollectedDataTypeEmailAddress",
        "NSPrivacyCollectedDataTypeName",
        "NSPrivacyCollectedDataTypeOtherUserContent",
        "NSPrivacyCollectedDataTypePurchaseHistory"
    ]

    private func loadManifest() throws -> [String: Any] {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: BundleToken.self)
        #endif

        let url = try #require(
            bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
            "PrivacyInfo.xcprivacy is not bundled with the target"
        )
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try #require(
            plist as? [String: Any],
            "PrivacyInfo.xcprivacy did not decode as a property-list dictionary"
        )
    }

    @Test func manifestIsPresentAndDecodes() throws {
        let manifest = try loadManifest()
        #expect(!manifest.isEmpty, "PrivacyInfo.xcprivacy decoded to an empty dictionary")
    }

    @Test func sdkDeclaresNoTracking() throws {
        let manifest = try loadManifest()
        let tracking = try #require(manifest["NSPrivacyTracking"] as? Bool, "NSPrivacyTracking must be a Bool")
        #expect(tracking == false, "The SDK performs no tracking — NSPrivacyTracking must stay false")
        let domains = try #require(manifest["NSPrivacyTrackingDomains"] as? [Any], "NSPrivacyTrackingDomains must be an array")
        #expect(domains.isEmpty, "The SDK must not declare tracking domains")
    }

    @Test func declaresUserDefaultsRequiredReasonCA92_1() throws {
        let manifest = try loadManifest()
        let apiTypes = try #require(
            manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]],
            "NSPrivacyAccessedAPITypes must be an array of dictionaries"
        )
        #expect(!apiTypes.isEmpty, "UserDefaults usage must be declared")

        let defaults = apiTypes.filter {
            ($0["NSPrivacyAccessedAPIType"] as? String) == "NSPrivacyAccessedAPICategoryUserDefaults"
        }
        #expect(defaults.count == 1, "Expected exactly one UserDefaults declaration")

        let reasons = try #require(
            defaults.first?["NSPrivacyAccessedAPITypeReasons"] as? [String],
            "UserDefaults declaration must carry reason codes"
        )
        #expect(reasons == ["CA92.1"], "UserDefaults reason codes must be exactly [CA92.1], found \(reasons)")

        let otherCategories = Set(
            apiTypes.compactMap { $0["NSPrivacyAccessedAPIType"] as? String }
        ).subtracting(["NSPrivacyAccessedAPICategoryUserDefaults"])
        #expect(otherCategories.isEmpty, "Unexpected additional required-reason API categories: \(otherCategories)")
    }

    @Test func declaresAllCollectedDataTypes() throws {
        let manifest = try loadManifest()
        let dataTypes = try #require(
            manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]],
            "NSPrivacyCollectedDataTypes must be an array of dictionaries"
        )
        let declared = Set(dataTypes.compactMap { $0["NSPrivacyCollectedDataType"] as? String })
        #expect(declared == Self.expectedCollectedDataTypes, "Declared data types drifted from the audited contract: found \(declared)")
    }

    @Test func collectedDataTypesAreUnlinkedAndNotUsedForTracking() throws {
        let manifest = try loadManifest()
        let dataTypes = try #require(
            manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]],
            "NSPrivacyCollectedDataTypes must be an array of dictionaries"
        )
        #expect(!dataTypes.isEmpty, "At least one collected data type must be declared")

        for entry in dataTypes {
            let name = (entry["NSPrivacyCollectedDataType"] as? String) ?? "<unnamed>"
            let linked = try #require(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, "\(name): NSPrivacyCollectedDataTypeLinked must be a Bool")
            let tracking = try #require(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, "\(name): NSPrivacyCollectedDataTypeTracking must be a Bool")
            #expect(linked == false, "\(name) must not be declared as linked to identity")
            #expect(tracking == false, "\(name) must not be declared as used for tracking")

            let purposes = try #require(entry["NSPrivacyCollectedDataTypePurposes"] as? [String], "\(name): purposes must be an array of strings")
            #expect(!purposes.isEmpty, "\(name) must declare at least one purpose")
            let allowed: Set<String> = [
                "NSPrivacyCollectedDataTypePurposeAppFunctionality",
                "NSPrivacyCollectedDataTypePurposeAnalytics"
            ]
            #expect(Set(purposes).isSubset(of: allowed), "\(name) declares unexpected purposes: \(purposes)")
        }
    }
}
