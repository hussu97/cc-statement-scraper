import AuthenticationServices
import Foundation
import Observation
@_spi(Experimental) import Supabase

/// A passkey on the signed-in account, as shown in Settings.
public struct LedgerPasskey: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let createdAt: Date
    public let lastUsedAt: Date?

    public init(id: UUID, name: String, createdAt: Date, lastUsedAt: Date?) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

/// Passkeys (Supabase Auth WebAuthn, relying party = the web app's host).
/// Sign-in lives on `SessionStore`; this store lists, adds, renames and
/// removes the signed-in user's passkeys and remembers "Not now".
@MainActor
@Observable
public final class PasskeyStore {
    public private(set) var state: LoadState<[LedgerPasskey]> = .idle
    public private(set) var isWorking = false
    public var errorMessage: String?

    private let auth: AuthClient
    private let defaults: UserDefaults

    public init(auth: AuthClient, defaults: UserDefaults = .standard) {
        self.auth = auth
        self.defaults = defaults
    }

    // MARK: Decisions (pure, unit-tested)

    /// Offer a passkey after an email-code sign-in only when the account has
    /// none (nil = couldn't tell, so don't nag) and the person hasn't said "Not now".
    public nonisolated static func shouldOffer(declined: Bool, passkeyCount: Int?) -> Bool {
        !declined && passkeyCount == 0
    }

    /// The default name for a passkey made in the app.
    public nonisolated static let appPasskeyName = "Bank Ledger on iPhone"

    /// The person dismissed the passkey prompt; not an error to show.
    public nonisolated static func isCancellation(_ error: any Error) -> Bool {
        if let e = error as? ASAuthorizationError { return e.code == .canceled }
        let ns = error as NSError
        return ns.domain == ASAuthorizationError.errorDomain && ns.code == ASAuthorizationError.Code.canceled.rawValue
    }

    /// Sentences for GoTrue's passkey error codes (same wording as the web app).
    public nonisolated static func message(forCode code: String) -> String? {
        switch code {
        case "webauthn_credential_not_found":
            "That passkey is no longer on your Bank Ledger account. Sign in with an email code, then add a new one."
        case "webauthn_challenge_expired", "webauthn_challenge_not_found":
            "The passkey prompt timed out. Try again."
        case "webauthn_verification_failed":
            "The passkey couldn't be verified. Try again, or sign in with an email code."
        case "webauthn_credential_exists":
            "This iPhone already has a passkey for your account."
        case "too_many_passkeys":
            "You've reached the passkey limit. Remove one in Settings first."
        case "passkey_disabled":
            "Passkeys are turned off for Bank Ledger right now. Use an email code."
        default:
            nil
        }
    }

    nonisolated static func message(for error: any Error) -> String {
        if let auth = error as? AuthError, let text = message(forCode: auth.errorCode.rawValue) { return text }
        return SessionStore.message(for: error)
    }

    // MARK: "Not now", per user, on this device

    private func declinedKey(_ userID: String) -> String { "ledger.passkeyOfferDeclined.\(userID)" }

    public func offerDeclined(userID: String) -> Bool { defaults.bool(forKey: declinedKey(userID)) }

    public func setOfferDeclined(_ declined: Bool, userID: String) {
        if declined { defaults.set(true, forKey: declinedKey(userID)) } else { defaults.removeObject(forKey: declinedKey(userID)) }
    }

    // MARK: Server calls

    /// nil when the list couldn't be fetched.
    public func count() async -> Int? {
        (try? await auth.listPasskeys())?.count
    }

    public func load() async {
        state = .loading(previous: state.value)
        do {
            let items = try await auth.listPasskeys()
            state = .loaded(items.map(Self.passkey))
        } catch {
            state = .failed(Self.message(for: error), previous: state.value)
        }
    }

    /// Runs the native passkey sheet and saves the passkey. Returns false when
    /// cancelled or failed (`errorMessage` says why on failure).
    @discardableResult
    public func add(anchor: ASPresentationAnchor) async -> Bool {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let item = try await auth.registerPasskey(presentationAnchor: anchor)
            if item.friendlyName?.isEmpty ?? true {
                _ = try? await auth.renamePasskey(id: item.id, friendlyName: Self.appPasskeyName)
            }
            await load()
            return true
        } catch {
            if !Self.isCancellation(error) { errorMessage = Self.message(for: error) }
            return false
        }
    }

    public func rename(_ id: UUID, to name: String) async {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !trimmed.isEmpty else { return }
        await mutate { _ = try await self.auth.renamePasskey(id: id, friendlyName: trimmed) }
    }

    public func remove(_ id: UUID) async {
        await mutate { try await self.auth.deletePasskey(id: id) }
    }

    private func mutate(_ body: @escaping @MainActor () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await body()
            await load()
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    nonisolated static func passkey(_ item: PasskeyListItem) -> LedgerPasskey {
        LedgerPasskey(id: item.id, name: (item.friendlyName?.isEmpty ?? true) ? "Passkey" : item.friendlyName!,
                      createdAt: item.createdAt, lastUsedAt: item.lastUsedAt)
    }
}
