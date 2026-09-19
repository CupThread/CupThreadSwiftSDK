import Foundation
import Testing

// Repository-level contract pinned for issue #12: the README declares MIT,
// so the root LICENSE must exist, carry the standard MIT grant, and stay in
// sync with the README's license section. `scripts/check-license.mjs` runs
// the same checks in CI; these tests surface drift during local `swift test`.
@Suite("LicenseConsistency")
struct LicenseConsistencyTests {
    private enum ContractError: Error {
        case repositoryRootNotFound
    }

    private let licenseText: String
    private let readmeText: String

    init() throws {
        var url = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            guard url.pathComponents.count > 1 else {
                throw ContractError.repositoryRootNotFound
            }
            url.deleteLastPathComponent()
        }
        licenseText = try String(contentsOf: url.appendingPathComponent("LICENSE"), encoding: .utf8)
        readmeText = try String(contentsOf: url.appendingPathComponent("README.md"), encoding: .utf8)
    }

    @Test func licenseFileCarriesStandardMITGrant() {
        #expect(licenseText.contains("MIT License"))
        #expect(licenseText.contains("Permission is hereby granted, free of charge"))
        #expect(licenseText.contains("Copyright (c) 2026 CupThread"))
    }

    @Test func readmeLicenseSectionAgreesWithLicenseFile() throws {
        let licenseSection = try #require(
            readmeText
                .split(separator: "\n## ")
                .first { $0.hasPrefix("License") }
        )
        #expect(licenseSection.contains("MIT"))
        #expect(licenseSection.contains("(LICENSE)"))
    }
}
