import Foundation
import Testing

/// Fails when the Demo reference integration regresses to creating
/// `FeedbackClient` / `UserTokenStore` as View stored properties or calling
/// the always-network `fetchAppConfig()` directly (issue #291).
///
/// The Demo app is the reference integration consumers copy, and
/// `FeedbackClient` is documented as "create once and share freely": its
/// search throttle/cooldown and short-TTL config cache only hold when every
/// surface shares one client. A client created as a View-struct `let` is
/// re-created on every parent re-evaluation and silently resets both. The
/// sanctioned owner is the app-level `DemoAppModel`.
@Suite("Demo reference integration guard")
struct DemoReferenceIntegrationGuardTests {
    private static let patterns: [(name: String, regex: NSRegularExpression)] = {
        let specs = [
            // `let client = FeedbackClient(...)` as a stored property — views
            // must receive the shared instance instead (receiving via
            // `let client: FeedbackClient` is fine; creation is not).
            ("view-owned client", #"let\s+\w+\s*=\s*FeedbackClient\s*\("#),
            ("view-owned token store", #"let\s+\w+\s*=\s*UserTokenStore\s*\("#),
            // The demo must resolve configuration through its shared
            // SdkConfigLoader (cache-coalescing), never the always-network
            // variant that duplicates the config GET.
            ("bypassing config fetch", #"fetchAppConfig\s*\("#)
        ]
        return specs.compactMap { name, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (name, regex)
        }
    }()

    private func demoDirectory() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            directory.deleteLastPathComponent()
            let candidate = directory
                .appendingPathComponent("Demo", isDirectory: true)
                .appendingPathComponent("CupThreadDemo", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        try #require(
            false,
            "Could not locate Demo/CupThreadDemo by walking up from \(#filePath)"
        )
        return URL(fileURLWithPath: #filePath) // unreachable; #require throws first
    }

    @Test func demoViewsNeverOwnClientsOrDuplicateConfigFetches() throws {
        let directory = try demoDirectory()
        let files = try #require(
            FileManager.default
                .enumerator(at: directory, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" },
            "Failed to enumerate Swift sources under \(directory)"
        )
        try #require(!files.isEmpty, "No Swift sources found under \(directory)")

        var violations: [String] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let source = try String(contentsOf: file, encoding: .utf8)
            let lines = source.components(separatedBy: .newlines)
            for (offset, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                    continue
                }
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                for (name, regex) in Self.patterns
                where regex.firstMatch(in: line, range: range) != nil {
                    violations.append("\(file.lastPathComponent):\(offset + 1) [\(name)] \(trimmed)")
                }
            }
        }

        #expect(
            violations.isEmpty,
            """
            The Demo app must create its FeedbackClient/UserTokenStore once in DemoAppModel and read \
            the configuration through the shared SdkConfigLoader — a View-struct stored property is \
            re-created on every parent re-evaluation and resets the shared search throttle and config \
            cache. Violations:
            \(violations.joined(separator: "\n"))
            """
        )
    }
}
