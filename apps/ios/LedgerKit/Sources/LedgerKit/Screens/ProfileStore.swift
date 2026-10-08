import Foundation
import Observation

/// The signed-in user's profiles and which one the app (and the SMS intent)
/// is pointed at.
@MainActor
@Observable
public final class ProfileStore {
    public private(set) var state: LoadState<[LedgerProfile]> = .idle
    public private(set) var memberships: [ProfileMembership] = []
    public private(set) var selectedCode: String?
    public var errorMessage: String?

    private let api: any LedgerAPI
    private let selection: ProfileSelection

    public init(api: any LedgerAPI, selection: ProfileSelection) {
        self.api = api
        self.selection = selection
        selectedCode = selection.profileCode
    }

    public var profiles: [LedgerProfile] { state.value ?? [] }
    public var selected: LedgerProfile? { profiles.first { $0.profileCode == selectedCode } }

    /// Offer "Switch ledger" only when there is another one to switch to.
    public var canSwitch: Bool { profiles.count > 1 }

    /// SMS ingest and uploads need the owner role.
    public var canWrite: Bool {
        memberships.first { $0.profileCode == selectedCode }?.isOwner ?? false
    }

    /// Loads profiles and keeps the stored selection when it is still valid;
    /// with exactly one profile it is selected automatically.
    public func load() async {
        state = state.startLoading()
        do {
            async let profiles = api.profiles()
            async let members = api.memberships()
            let (p, m) = try await (profiles, members)
            memberships = m
            state = .loaded(p)
            select(Self.resolveSelection(stored: selectedCode, profiles: p))
        } catch {
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
