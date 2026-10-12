import Foundation
import Testing
@testable import LedgerKit

/// The phone's OTP filter and the server's (`private.sms_otp_pattern()`, used by `ingest_sms`)
/// are one pattern (audit IOS-10). The fixture lives in the pgTAP test
/// `supabase/tests/38_sms_otp_filter.test.sql`, which runs it against the database; this suite
/// reads the same file and runs it against `SMSCapture`. Its `not_otp` list holds every server
/// SMS template example (pgTAP fails when one is missing), so a pattern that would drop a real
/// purchase, refund, payment or decline alert fails here as well as there.
@Suite("SMS OTP filter: the same pattern and the same answers as the server")
struct SMSOTPParityTests {
    struct Fixture: Decodable {
        let pattern: String
        let otp: [String]
        let notOTP: [String]

        enum CodingKeys: String, CodingKey {
            case pattern, otp
            case notOTP = "not_otp"
        }
    }

    struct FixtureMissing: Error, CustomStringConvertible {
        let description: String
    }

    /// `…/apps/ios/LedgerKit/Tests/LedgerKitTests/<this file>` → the repository root.
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }()

    static func fixture() throws -> Fixture {
        let file = repoRoot.appending(path: "supabase/tests/38_sms_otp_filter.test.sql")
        let sql = try String(contentsOf: file, encoding: .utf8)
        let parts = sql.components(separatedBy: "$sms_otp_fixture$")
        guard parts.count == 3 else {
            throw FixtureMissing(description: "expected one $sms_otp_fixture$…$sms_otp_fixture$ literal in \(file.path)")
        }
        return try JSONDecoder().decode(Fixture.self, from: Data(parts[1].utf8))
    }

    @Test("the device's pattern is the server's, character for character")
    func samePattern() throws {
        #expect(SMSCapture.otpPatternSource == (try Self.fixture().pattern))
    }

    @Test("every OTP in the shared fixture is dropped on the device")
    func dropsEveryOTP() throws {
        let fixture = try Self.fixture()
        #expect(fixture.otp.count >= 20)
        let missed = fixture.otp.filter { SMSCapture.classify(body: $0) != .dropOTP }
        #expect(missed.isEmpty, "not caught: \(missed)")
    }

    @Test("every template example and other real message in the shared fixture is sent")
    func sendsEveryNonOTP() throws {
        let fixture = try Self.fixture()
        #expect(fixture.notOTP.count >= 50)
        let dropped = fixture.notOTP.filter { SMSCapture.classify(body: $0) != .accept }
        #expect(dropped.isEmpty, "dropped as OTP: \(dropped)")
    }
}
