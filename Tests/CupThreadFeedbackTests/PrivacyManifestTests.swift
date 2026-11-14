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

    /// The required-reason categories the audited call sites justify, pinned
    /// exactly: adding a third category requires updating this expectation.
    private static let auditedRequiredReasonAPIs: [String: [String]] = [
        "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
        "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1", "3B52.1"]
    ]

    /// Tokens that appear at a required-reason API call site. Every match in
    /// `Sources/CupThreadFeedback` must have its category declared.
    private static let requiredReasonCallSites: [(token: String, category: String)] = [
        ("UserDefaults", "NSPrivacyAccessedAPICategoryUserDefaults"),
        ("attributesOfItem", "NSPrivacyAccessedAPICategoryFileTimestamp"),
        ("contentModificationDate", "NSPrivacyAccessedAPICategoryFileTimestamp"),
        ("getattrlist", "NSPrivacyAccessedAPICategoryFileTimestamp"),
        ("getattrlist", "NSPrivacyAccessedAPICategoryDiskSpace"),
        ("stat(", "NSPrivacyAccessedAPICategoryFileTimestamp"),
        ("fstatat(", "NSPrivacyAccessedAPICategoryFileTimestamp"),
        ("systemUptime", "NSPrivacyAccessedAPICategorySystemBootTime"),
        ("mach_absolute_time", "NSPrivacyAccessedAPICategorySystemBootTime"),
        ("volumeAvailableCapacity", "NSPrivacyAccessedAPICategoryDiskSpace"),
        ("volumeTotalCapacity", "NSPrivacyAccessedAPICategoryDiskSpace"),
        ("systemFreeSize", "NSPrivacyAccessedAPICategoryDiskSpace"),
        ("systemSize", "NSPrivacyAccessedAPICategoryDiskSpace"),
        ("statfs", "NSPrivacyAccessedAPICategoryDiskSpace"),
        ("statvfs", "NSPrivacyAccessedAPICategoryDiskSpace"),
        ("activeInputModes", "NSPrivacyAccessedAPICategoryActiveKeyboards")
    ]

    @Test func declaresExactlyTheAuditedRequiredReasonCategories() throws {
        let manifest = try loadManifest()
        let apiTypes = try #require(
            manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]],
            "NSPrivacyAccessedAPITypes must be an array of dictionaries"
        )

        var declared: [String: [String]] = [:]
        for entry in apiTypes {
            let category = try #require(
                entry["NSPrivacyAccessedAPIType"] as? String,
                "Every NSPrivacyAccessedAPITypes entry needs an NSPrivacyAccessedAPIType string"
            )
            let reasons = try #require(
                entry["NSPrivacyAccessedAPITypeReasons"] as? [String],
                "\(category) must carry reason codes"
            )
            #expect(declared[category] == nil, "\(category) is declared more than once")
            declared[category] = reasons
        }

        #expect(
            declared == Self.auditedRequiredReasonAPIs,
            "Required-reason declarations drifted from the audited contract: found \(declared)"
        )
    }

    @Test func everyRequiredReasonCallIsDeclared() throws {
        let manifest = try loadManifest()
        let apiTypes = try #require(
            manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]],
            "NSPrivacyAccessedAPITypes must be an array of dictionaries"
        )
        let declared = Set(apiTypes.compactMap { $0["NSPrivacyAccessedAPIType"] as? String })

        var undeclared: Set<String> = []
        for file in try sourceFiles() {
            let code = try String(contentsOf: file, encoding: .utf8)
            for call in Self.requiredReasonCallSites
            where code.contains(call.token) && !declared.contains(call.category) {
                undeclared.insert("\(file.lastPathComponent): \(call.token) needs \(call.category)")
            }
        }

        #expect(
            undeclared.isEmpty,
            "Required-reason API call sites are missing manifest declarations: \(undeclared.sorted())"
        )
    }

    /// Every Swift source shipped by the library target, resolved from this
    /// test file so it works from any checkout location.
    private func sourceFiles() throws -> [URL] {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PrivacyManifestTests.swift
            .deletingLastPathComponent() // CupThreadFeedbackTests
            .deletingLastPathComponent() // Tests
            .appending(path: "Sources/CupThreadFeedback")
        let enumerator = try #require(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: [.isRegularFileKey]),
            "Could not enumerate \(sources.path)"
        )

        var files: [URL] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            files.append(file)
        }
        #expect(!files.isEmpty, "No Swift sources found under \(sources.path)")
        return files
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
