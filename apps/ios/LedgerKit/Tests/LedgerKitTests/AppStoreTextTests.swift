import Foundation
import Testing

/// App Store processing rejects a build whose App Intent, App Shortcut, widget
/// or Control text names an Apple product (ITMS-90626; build 2 was rejected for
/// "iPhone"). apps/ios/CLAUDE.md states the rule; this enforces it for every
/// source in the intents and the widget extension, comments included.
@Suite("No Apple product names in intent, shortcut, widget or Control text (ITMS-90626)")
struct AppStoreTextTests {
    static let iosRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    static let banned = ["iPhone", "iPad", "Siri", "Apple Watch"]

    @Test(arguments: ["Ledger/Intents", "Widgets", "Shared"])
    func noTrademarks(directory: String) throws {
        let dir = Self.iosRoot.appendingPathComponent(directory)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for word in Self.banned {
                #expect(!text.contains(word), "\(file.lastPathComponent) contains \(word)")
            }
        }
    }
}
