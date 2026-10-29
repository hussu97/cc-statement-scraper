import Foundation
import Testing

/// The repository is public: the app's identity (Apple team, bundle prefix, passkey
/// host) lives only in the gitignored `Config/Identity.xcconfig`. These guard the
/// committed files that XcodeGen and Xcode write, so a regeneration or an Xcode
/// "Signing & Capabilities" edit cannot put a real value back unnoticed.
@Suite("Committed project files carry no app identity")
struct IdentityGuardTests {
    /// apps/ios
    private static let iosRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func read(_ path: String) throws -> String {
        try String(contentsOf: iosRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// `KEY = value` lines of an xcconfig, comments dropped.
    private static func xcconfigValues(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("//"), !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            values[key] = value
        }
        return values
    }

    /// Every `NAME = value;` assignment in the pbxproj, value unquoted.
    private static func pbxValues(_ name: String, in text: String) -> [String] {
        let pattern = "\\b\(name) = (\"[^\"]*\"|[^;]*);"
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
    }

    @Test("Base.xcconfig holds neutral defaults and includes Identity.xcconfig last")
    func baseDefaultsAreNeutral() throws {
        let text = try Self.read("Config/Base.xcconfig")
        let values = Self.xcconfigValues(text)
        #expect(values["LEDGER_BUNDLE_PREFIX"] == "com.example.ledger")
        #expect(values["LEDGER_PASSKEY_DOMAIN"] == "example.com")
        #expect(values["DEVELOPMENT_TEAM"] == "")
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }
        #expect(lines.last == "#include? \"Identity.xcconfig\"")
    }

    @Test("the template names no real identity")
    func templateIsNeutral() throws {
        let values = Self.xcconfigValues(try Self.read("Config/Identity.example.xcconfig"))
        #expect(values["LEDGER_BUNDLE_PREFIX"] == "com.example.ledger")
        #expect(values["LEDGER_PASSKEY_DOMAIN"] == "example.com")
        #expect(values["DEVELOPMENT_TEAM"] == "<apple-team-id>")
    }

    @Test("the Xcode project has no team ID and derives every bundle id from the prefix")
    func pbxprojIsNeutral() throws {
        let text = try Self.read("Ledger.xcodeproj/project.pbxproj")
        // XcodeGen copies the resolved DEVELOPMENT_TEAM into TargetAttributes.
        let teams = Self.pbxValues("DevelopmentTeam", in: text) + Self.pbxValues("DEVELOPMENT_TEAM", in: text)
        for team in teams {
            #expect(team.isEmpty || team.hasPrefix("$("), "team ID in project.pbxproj")
        }
        let bundleIDs = Self.pbxValues("PRODUCT_BUNDLE_IDENTIFIER", in: text)
        #expect(!bundleIDs.isEmpty)
        for id in bundleIDs {
            #expect(id.hasPrefix("$(LEDGER_BUNDLE_PREFIX)"), "literal bundle id in project.pbxproj")
        }
    }

    @Test("project.yml's XcodeGen fallback prefix is neutral")
    func projectSpecIsNeutral() throws {
        let text = try Self.read("project.yml")
        #expect(text.contains("bundleIdPrefix: com.example.ledger"))
        #expect(!text.contains("DEVELOPMENT_TEAM:"))
    }
}
