import Foundation
import Testing

/// "Log Bank SMS" and "Log Card Payment" run inside personal automations, where
/// nobody is there to answer. A non-optional `@Parameter` that arrives empty
/// makes iOS ask for a value instead of running `perform()`: build 32 hung on
/// launch that way (Sentry 7796165023, an `LNNeedsValueRequest` in flight).
/// Every parameter of an `openAppWhenRun = false` intent without a
/// `requestValueDialog` is optional, so LedgerKit refuses empty input itself
/// (`SMSCapture.dropEmpty`, `WalletCapture.Problem.missing*`).
@Suite("Background capture intents never ask for a value")
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
}
