import Foundation
import Observation

/// Shows an SMS's text on request (Review's "Show message", like the web's): read from the
/// server each time it opens, held only while it is open, never logged or stored.
@MainActor
@Observable
public final class SMSTextReveal {
    /// Open messages: their text, or loading / failed.
    public private(set) var open: [String: LoadState<String>] = [:]
    private let api: any LedgerAPI

    public init(api: any LedgerAPI) { self.api = api }

    public func isOpen(_ smsCode: String) -> Bool { open[smsCode] != nil }

    /// "Show message" / "Hide message".
    public func toggleLabel(_ smsCode: String) -> String { isOpen(smsCode) ? "Hide message" : "Show message" }

    public func toggle(_ smsCode: String, profileCode: String) async {
        if open[smsCode] != nil {
            open[smsCode] = nil
            return
        }
        open[smsCode] = .loading(previous: nil)
        do {
            let body = try await api.smsBody(profileCode: profileCode, smsCode: smsCode)
            guard open[smsCode] != nil else { return }   // closed while loading
            open[smsCode] = .loaded(body ?? "")
        } catch {
            guard open[smsCode] != nil else { return }
            open[smsCode] = .failed("Couldn't load the message.", previous: nil)
        }
    }

    /// Another ledger, sign-out: no text stays in memory.
    public func closeAll() { open = [:] }
}
