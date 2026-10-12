import AuthenticationServices
import Foundation
import Observation
@_spi(Experimental) import Supabase

/// Sign-in state for the app: an emailed one-time code or a passkey, plus a
/// password for accounts that have one (only the App Review demo account does;
/// everyone else has no password, so the form can't sign them in). No magic link.
/// After a code sign-in the app offers to add a passkey (`passkeyOffer`); "Not
/// now" is remembered per user on this device.
@MainActor
@Observable
public final class SessionStore {
    public enum Phase: Equatable, Sendable {
        case restoring
        case signedOut
        case awaitingCode(email: String)
        case signedIn(userID: String, email: String?)
    }

    /// After an email-code sign-in: deciding whether to offer a passkey, or offering it.
    public enum PasskeyOffer: Equatable, Sendable {
        case none
        case checking
        case offering(userID: String)
    }

    public private(set) var phase: Phase = .restoring
    public private(set) var isWorking = false
    public private(set) var passkeyOffer: PasskeyOffer = .none
    public let passkeys: PasskeyStore
    public var errorMessage: String?
    /// Debug builds only: the keychain refused the session, so it is kept in
    /// memory for this run (the App Intent and Share Extension can't see it).
    public private(set) var sessionInMemoryOnly = false

    private let auth: AuthClient
    private let storage: SharedKeychainStorage?
    private var listener: Task<Void, Never>?

    public init(client: SupabaseClient, storage: SharedKeychainStorage? = nil, defaults: UserDefaults = .standard) {
        auth = client.auth
        self.storage = storage
        passkeys = PasskeyStore(auth: client.auth, defaults: defaults)
    }

    /// What a session event means once we know whether the session was saved.
    public enum Persistence: Equatable, Sendable {
        case saved
        /// Kept in memory (Debug fallback): usable in this process only.
        case memoryOnly
        case failed(OSStatus)
    }

    /// A sign-in whose session could not be saved is not a sign-in: every
    /// request would go out with only the publishable key. Pure, so it is unit-tested.
    public nonisolated static func phase(signedInAs userID: String, email: String?,
                                         persistence: Persistence) -> (phase: Phase, error: String?) {
        switch persistence {
        case .saved, .memoryOnly:
            return (.signedIn(userID: userID, email: email), nil)
        case .failed(let status):
            return (.signedOut, "Couldn't save your sign-in on this iPhone (keychain error \(status)). Try again; if it keeps failing, reinstall Bank Ledger.")
        }
    }

    private var persistence: Persistence {
        guard let storage else { return .saved }
        if storage.isUsingMemoryFallback { return .memoryOnly }
        if let failure = storage.persistenceFailure { return .failed(failure.status) }
        return .saved
    }

    /// Restores the stored session and follows auth events for the app's lifetime.
    public func start() {
        guard listener == nil else { return }
        listener = Task { [weak self, auth] in
            for await (event, session) in auth.authStateChanges {
                guard let self else { return }
                switch event {
                case .initialSession, .signedIn, .tokenRefreshed, .userUpdated:
                    // An expired stored session is still "signed in": the client
                    // refreshes it next and emits `.signedOut` if that fails.
                    if let session {
                        let id = session.user.id.uuidString.lowercased()
                        let persistence = self.persistence
                        let (phase, error) = Self.phase(signedInAs: id, email: session.user.email, persistence: persistence)
                        self.sessionInMemoryOnly = persistence == .memoryOnly
                        self.phase = phase
                        if let error {
                            self.errorMessage = error
                            if let failure = self.storage?.persistenceFailure {
                                Telemetry.capture(failure, tags: ["area": "keychain"])
                            }
                            Telemetry.setUser(id: nil)
                        } else {
                            Telemetry.setUser(id: id)
                        }
                    } else if event == .initialSession {
                        self.phase = .signedOut
                    }
                case .signedOut:
                    self.phase = .signedOut
                    self.passkeyOffer = .none
                    Telemetry.setUser(id: nil)
                default:
                    break
                }
            }
        }
    }

    public func sendCode(to email: String) async {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.isPlausibleEmail(trimmed) else {
            errorMessage = "Enter a valid email address."
            return
        }
        await run {
            // Invite-only: an unknown email never creates an account.
            try await self.auth.signInWithOTP(email: trimmed, shouldCreateUser: false)
            self.phase = .awaitingCode(email: trimmed)
        }
    }

    public func verify(code: String) async {
        guard case .awaitingCode(let email) = phase else { return }
        let digits = code.filter(\.isNumber)
        guard (6...10).contains(digits.count) else {
            errorMessage = "Enter the code from the email."
            return
        }
        // Hold the route on the sign-in screen until we know whether to offer a passkey.
        passkeyOffer = .checking
        var userID: String?
        await run {
            let response = try await self.auth.verifyOTP(email: email, token: digits, type: .email)
            userID = response.user.id.uuidString.lowercased()
        }
        guard let userID else {
            passkeyOffer = .none
            return
        }
        let count = await passkeys.count()
        let offer = PasskeyStore.shouldOffer(declined: passkeys.offerDeclined(userID: userID), passkeyCount: count)
        passkeyOffer = offer ? .offering(userID: userID) : .none
    }

    /// Discoverable passkey sign-in: no email needed. Cancelling the sheet is silent.
    public func signInWithPasskey(anchor: ASPresentationAnchor) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await auth.signInWithPasskey(presentationAnchor: anchor)
        } catch {
            if !PasskeyStore.isCancellation(error) { errorMessage = PasskeyStore.message(for: error) }
        }
    }

    /// "Add a passkey" on the post-sign-in offer. Cancelling keeps the offer up.
    public func acceptPasskeyOffer(anchor: ASPresentationAnchor) async {
        if await passkeys.add(anchor: anchor) { passkeyOffer = .none }
    }

    /// "Not now": remembered for this user on this device; Settings can still add one.
    public func declinePasskeyOffer() {
        if case .offering(let userID) = passkeyOffer { passkeys.setOfferDeclined(true, userID: userID) }
        passkeys.errorMessage = nil
        passkeyOffer = .none
    }

    /// Password sign-in. Production accounts sign in with a code or a passkey and
    /// have no password; this exists for the App Review demo account (Guideline
    /// 2.1(a): the reviewer needs a username and password) and the local seed users.
    public func signIn(email: String, password: String) async {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.canSubmitPassword(email: trimmed, password: password) else {
            errorMessage = "Enter your email and password."
            return
        }
        await run { _ = try await self.auth.signIn(email: trimmed, password: password) }
    }

    /// The password form's Sign in button is enabled only for a plausible email
    /// and a non-empty password.
    public nonisolated static func canSubmitPassword(email: String, password: String) -> Bool {
        isPlausibleEmail(email.trimmingCharacters(in: .whitespacesAndNewlines)) && !password.isEmpty
    }

    public func cancelCode() {
        phase = .signedOut
        errorMessage = nil
    }

    public func signOut() async {
        await run { try await self.auth.signOut(scope: .local) }
        passkeyOffer = .none
        phase = .signedOut
    }

    private func run(_ body: @escaping @MainActor () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do { try await body() } catch { errorMessage = Self.message(for: error) }
    }

    nonisolated static func message(for error: any Error) -> String {
        if let auth = error as? AuthError { return auth.message }
        if error is URLError { return "No connection to Bank Ledger." }
        return error.localizedDescription
    }

    public nonisolated static func isPlausibleEmail(_ s: String) -> Bool {
        s.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]{2,}$"#, options: .regularExpression) != nil
    }
}
