import Foundation
import Observation

/// The signed-in user's profiles: which one the app shows, and which one SMS
/// and shared PDFs are filed in ("SMS go to" — owned ledgers only).
@MainActor
@Observable
public final class ProfileStore {
    public private(set) var state: LoadState<[LedgerProfile]> = .idle
    public private(set) var memberships: [ProfileMembership] = []
    public private(set) var selectedCode: String?
    public private(set) var smsTarget: SMSTarget?
    public var errorMessage: String?
    /// The last load failed because the server rejected the stored session
    /// (revoked, expired beyond refresh, or issued by another project). The app
    /// signs out locally instead of showing "You are signed out" on a signed-in screen.
    public private(set) var sessionRejected = false

    private let api: any LedgerAPI
    private let selection: ProfileSelection
    private let smsTargets: SMSTargetStore?

    public init(api: any LedgerAPI, selection: ProfileSelection, smsTargets: SMSTargetStore? = nil) {
        self.api = api
        self.selection = selection
        self.smsTargets = smsTargets
        selectedCode = selection.profileCode
        smsTarget = smsTargets?.target
    }

    public var profiles: [LedgerProfile] { state.value ?? [] }
    public var selected: LedgerProfile? { profiles.first { $0.profileCode == selectedCode } }

    /// Offer "Switch ledger" only when there is another one to switch to.
    public var canSwitch: Bool { profiles.count > 1 }

    /// SMS ingest, statement uploads and review decisions need the owner role.
    public var canWrite: Bool { isOwner(of: selectedCode) }

    public func isOwner(of code: String?) -> Bool {
        memberships.first { $0.profileCode == code }?.isOwner ?? false
    }

    /// Ledgers the user may file SMS in (owned only).
    public var smsEligible: [LedgerProfile] {
        SMSTarget.eligible(profiles: profiles, memberships: memberships)
    }

    /// Points SMS and shared PDFs at an owned ledger. Ignores anything else.
    public func setSMSTarget(_ code: String) {
        guard let profile = smsEligible.first(where: { $0.profileCode == code }) else { return }
        storeSMSTarget(SMSTarget(profileCode: profile.profileCode, name: profile.name))
    }

    private func storeSMSTarget(_ target: SMSTarget?) {
        smsTarget = target
        smsTargets?.target = target
    }

    /// Loads profiles and keeps the stored selection when it is still valid;
    /// with exactly one profile it is selected automatically.
    public func load() async {
        state = state.startLoading()
        sessionRejected = false
        do {
            async let profiles = api.profiles()
            async let members = api.memberships()
            let (p, m) = try await (profiles, members)
            memberships = m
            state = .loaded(p)
            select(Self.resolveSelection(stored: selectedCode, profiles: p))
            storeSMSTarget(SMSTarget.resolve(stored: smsTargets?.target ?? smsTarget, profiles: p, memberships: m))
        } catch {
            sessionRejected = (error as? LedgerAPIError) == .notSignedIn
            state = state.fail(error)
        }
    }

    public func select(_ code: String?) {
        selectedCode = code
        selection.profileCode = code
        Telemetry.setProfile(code: code)
    }

    /// Creates a ledger for the signed-in user and selects it.
    public func create(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Give the ledger a name."
            return
        }
        do {
            let code = try await api.createProfile(key: Self.key(for: trimmed), name: trimmed)
            selectedCode = code
            await load()
            select(code)
        } catch {
            errorMessage = LoadState<Int>.message(for: error)
        }
    }

    public func reset() {
        select(nil)
        storeSMSTarget(nil)
        state = .idle
        memberships = []
    }

    /// Keep the stored choice if it still exists; auto-pick a lone profile.
    public nonisolated static func resolveSelection(stored: String?, profiles: [LedgerProfile]) -> String? {
        if let stored, profiles.contains(where: { $0.profileCode == stored }) { return stored }
        return profiles.count == 1 ? profiles[0].profileCode : nil
    }

    /// `profiles.key` must match `^[a-z0-9_-]{2,40}$` and be unique; a short
    /// random suffix avoids collisions between two people both called "Home".
    public nonisolated static func key(for name: String, suffix: String = String(UUID().uuidString.prefix(6)).lowercased()) -> String {
        let slug = name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
        let collapsed = String(slug).split(separator: "-").joined(separator: "-")
        let base = collapsed.isEmpty ? "ledger" : String(collapsed.prefix(30))
        return "\(base)-\(suffix)"
    }
}
