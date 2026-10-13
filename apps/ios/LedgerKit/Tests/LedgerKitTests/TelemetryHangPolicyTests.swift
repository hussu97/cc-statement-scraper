import Foundation
import Testing
@testable import LedgerKit

@Suite("App hangs: the app reports fully-blocking hangs only")
struct TelemetryHangPolicyTests {
    @Test("the app tracks hangs of 2 s or more, fully-blocking only")
    func app() {
        let hangs = HangReporting.forTarget(.app)
        #expect(hangs.enabled)
        #expect(hangs.timeout == 2)
        // Frames still rendering: the stack isn't the blocking call (build 26, a
        // double-tap in a text field on an iOS beta). Not reported.
        #expect(!hangs.reportsNonFullyBlocking)
    }

    @Test("the App Intent, the Share Extension and the widgets track no hangs", arguments: [TelemetryTarget.intent, .shareExtension, .widgets])
    func headless(target: TelemetryTarget) {
        let hangs = HangReporting.forTarget(target)
        #expect(!hangs.enabled)
        #expect(!hangs.reportsNonFullyBlocking)
    }
}
