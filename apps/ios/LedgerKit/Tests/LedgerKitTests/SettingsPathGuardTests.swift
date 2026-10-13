import Foundation
import Testing

/// Settings' NavigationStack has a typed path (`[SettingsRoute]`, so a deep link
/// can push Statements). A `NavigationLink(value:)` of any other type inside it
/// has no destination and the row silently does nothing: statement cycles
/// didn't open from build 29 until this guard.
@Suite("Settings stack pushes only SettingsRoute values")
struct SettingsPathGuardTests {
    static let viewDirs = ["apps/ios/Ledger/Settings", "apps/ios/Ledger/Statements"]

    @Test("links and destinations under Settings and Statements use SettingsRoute")
    func onlySettingsRoutes() throws {
        let root = AnalysisContractTests.repoRoot
        var offenders: [String] = []
        for dir in Self.viewDirs {
            let folder = root.appendingPathComponent(dir)
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" }
            #expect(!files.isEmpty, "no Swift files in \(dir)")
            for file in files {
                let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                for (index, line) in lines.enumerated() {
                    let code = line.trimmingCharacters(in: .whitespaces)
                    if code.hasPrefix("//") { continue }
                    let badLink = code.contains("NavigationLink(value:") && !code.contains("NavigationLink(value: SettingsRoute.")
                    let badDestination = code.contains(".navigationDestination(for:")
                        && !code.contains(".navigationDestination(for: SettingsRoute.self")
                    if badLink || badDestination {
                        offenders.append("\(dir)/\(file.lastPathComponent):\(index + 1)")
                    }
                }
            }
        }
        #expect(offenders.isEmpty, "push a SettingsRoute instead: \(offenders)")
    }
}
