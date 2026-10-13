import Foundation
import Sentry
import Testing
@testable import LedgerKit

@Suite("Telemetry scrubber — no SMS text, tokens or emails reach Sentry")
struct TelemetryScrubberTests {
    let sms = "Your FAB Credit Card XXX1234 was used for AED 45.10 at CARREFOUR CITY CENTRE"
    let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijk"

    func crumb(_ message: String?, data: [String: Any]? = nil) -> Breadcrumb {
        let b = Breadcrumb(level: .info, category: "test")
        b.message = message
        for (key, value) in data ?? [:] { b.setData(value: value, key: key) }
        return b
    }

    @Test("breadcrumbs carrying SMS text are dropped; outcome-only ones are kept")
    func breadcrumbs() {
        #expect(TelemetryScrubber.scrub(breadcrumb: crumb(sms)) == nil)
        #expect(TelemetryScrubber.scrub(breadcrumb: crumb("ingest", data: ["body": "hello"])) == nil)
        #expect(TelemetryScrubber.scrub(breadcrumb: crumb("ingest", data: ["nested": ["x": sms]])) == nil)
        #expect(TelemetryScrubber.scrub(breadcrumb: crumb("OTP 482913 for your purchase")) == nil)
        #expect(TelemetryScrubber.scrub(breadcrumb: crumb("Bearer \(jwt)")) == nil)
        let kept = crumb("delivered_new", data: ["profile_code": "prf_01hzy3k8w9m2n4p6q8r0s2t4v6"])
        #expect(TelemetryScrubber.scrub(breadcrumb: kept) === kept)
    }

    @Test("event extras, tags, message, exception values, request and user are scrubbed")
    func event() throws {
        let event = Event(level: .error)
        event.message = SentryMessage(formatted: "failed to ingest: \(sms)")
        event.extra = ["sms_body": "anything", "note": sms, "count": 3, "doc_code": "doc_01hzy3k8w9m2n4p6q8r0s2t4v6"]
        event.tags = ["target": "intent", "email": "a@b.co", "free": "card ending 1234 AED 5"]
        let exception = Exception(value: "decode failed for \(sms)", type: "DecodingError")
        event.exceptions = [exception]
        event.breadcrumbs = [crumb(sms), crumb("delivered_new")]
        let request = SentryRequest()
        request.headers = ["Authorization": "Bearer \(jwt)", "apikey": "anon", "X-Profile-Key": "home", "Accept": "application/json"]
        request.cookies = "sb=1"
        event.request = request
        let user = User(userId: "4b1c…")
        user.email = "alice@example.com"
        user.ipAddress = "1.2.3.4"
        event.user = user
        event.context = ["device": ["arch": "ARM64"], "custom": ["text": sms, "ok": "yes"]]

        let out = try #require(TelemetryScrubber.scrub(event))
        #expect(out.message?.formatted == "[redacted]")
        #expect(out.extra?.keys.sorted() == ["count", "doc_code"])
        #expect(out.tags == ["target": "intent"])
        #expect(out.exceptions?.first?.value == "[redacted]")
        #expect(out.breadcrumbs?.map(\.message) == ["delivered_new"])
        #expect(out.request?.headers == ["Accept": "application/json"])
        #expect(out.request?.cookies == nil)
        #expect(out.user?.userId == "4b1c…")
        #expect(out.user?.email == nil)
        #expect(out.user?.ipAddress == nil)
        #expect(out.context?["device"]?["arch"] as? String == "ARM64")
        #expect(out.context?["custom"]?.keys.sorted() == ["ok"])
    }

    @Test("sensitive-text detection", arguments: [
        ("Purchase of AED 1,250.00 with Credit Card ending 5678", true),
        ("Your Debit Card ending 1234 was used", true),
        ("482913 is your one-time password", true),
        ("user alice@example.com signed in", true),
        ("token ccs_abcdefgh12345678", true),
        ("Bearer abc.def.ghijklmnop", true),
        ("ingest_sms failed with PGRST301", false),
        ("profile prf_01hzy3k8w9m2n4p6q8r0s2t4v6 loaded", false),
        ("delivered_unknown_card", false),
    ])
    func detection(text: String, sensitive: Bool) {
        #expect(SensitiveText.containsSensitive(text) == sensitive)
    }

    @Test("release name comes from the bundle version")
    func release() {
        #expect(Telemetry.releaseName(info: ["CFBundleShortVersionString": "1.2.0", "CFBundleVersion": "42"]) == "ledger-ios@1.2.0+42")
        #expect(Telemetry.releaseName(info: nil) == "ledger-ios@0.0.0+0")
    }

    @Test("every target tags app=ios for the shared ledger-apps project, plus its target")
    func scopeTags() {
        #expect(Telemetry.scopeTags(target: .app) == ["app": "ios", "target": "app"])
        #expect(Telemetry.scopeTags(target: .intent) == ["app": "ios", "target": "intent"])
        #expect(Telemetry.scopeTags(target: .shareExtension) == ["app": "ios", "target": "share_extension"])
    }
}
