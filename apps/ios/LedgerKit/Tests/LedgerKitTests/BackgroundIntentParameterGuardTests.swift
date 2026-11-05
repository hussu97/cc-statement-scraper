import Foundation
import Testing

/// "Log Bank SMS" and "Log Card Payment" run inside personal automations, where
/// nobody is there to answer. A non-optional `@Parameter` that arrives empty
/// makes iOS ask for a value instead of running `perform()`: build 32 hung on
/// launch that way (Sentry 7796165023, an `LNNeedsValueRequest` in flight).
/// Every parameter of an `openAppWhenRun = false` intent without a
/// `requestValueDialog` is optional, so LedgerKit refuses empty input itself
/// (`SMSCapture.dropEmpty`, `WalletCapture.Problem.missing*`).
@Suite("Background capture intents never ask for a value or show a dialog")
struct BackgroundIntentParameterGuardTests {
    static let files = ["apps/ios/Ledger/Intents/LogBankSMSIntent.swift",
                        "apps/ios/Ledger/Intents/LogCardPaymentIntent.swift"]

    @Test("every @Parameter of the capture intents is optional")
    func parametersAreOptional() throws {
        let root = AnalysisContractTests.repoRoot
        var offenders: [String] = []
        for path in Self.files {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            #expect(source.contains("openAppWhenRun = false"), "\(path) is no longer a background intent")
            let lines = source.components(separatedBy: "\n")
            var inParameter = false
            var parameters = 0
            for (index, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("@Parameter") { inParameter = true }
                guard inParameter, code.hasPrefix("var ") else { continue }
                inParameter = false
                parameters += 1
                if !code.hasSuffix("?") { offenders.append("\(path):\(index + 1)") }
            }
            #expect(parameters > 0, "no @Parameter found in \(path)")
        }
        #expect(offenders.isEmpty, "make these optional and let LedgerKit refuse empty input: \(offenders)")
    }

    /// A dialog is a request to show something, and a background automation has
    /// no one to show it to: iOS 26 drops it and posts "ToolKit client
    /// implementation did not implement a ToolDialogHandler…" as a notification on
    /// every run. The capture intents return a value only; what needs the person
    /// is a local notification (`LocalNotifications.afterCapture`).
    @Test("the capture intents return no dialog")
    func noDialog() throws {
        let root = AnalysisContractTests.repoRoot
        var offenders: [String] = []
        for path in Self.files {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            for token in ["ProvidesDialog", "dialog:", "IntentDialog", "requestValue", "requestConfirmation",
                          "requestDisambiguation", "needsValueError"] where source.contains(token) {
                offenders.append("\(path): \(token)")
            }
        }
        #expect(offenders.isEmpty, "a background automation can't show a dialog: \(offenders)")
    }

    /// An App Shortcut runs with the parameters fixed in `AppShortcutsProvider`
    /// (none here), and iOS 26 offers its tile in an automation's "Do" picker
    /// with no way to bind Shortcut Input: picked, it always ran empty and was
    /// refused. The capture intents are actions only.
    @Test("the capture intents are not App Shortcuts")
    func notAppShortcuts() throws {
        let app = AnalysisContractTests.repoRoot.appendingPathComponent("apps/ios/Ledger")
        let files = try #require(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            let flat = source.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            for intent in ["LogBankSMSIntent", "LogCardPaymentIntent"] where flat.contains("AppShortcut(intent:\(intent)(") {
                offenders.append("\(url.lastPathComponent): \(intent)")
            }
        }
        #expect(offenders.isEmpty, "an automation can't feed an App Shortcut's parameters: \(offenders)")
    }
}
