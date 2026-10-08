import Foundation
import Observation
import Supabase

/// Sign-in state for the app. Email OTP is the primary path; Sign in with
/// Apple is behind `appleSignInEnabled` until the provider is configured.
@MainActor
@Observable
public final class SessionStore {
    public enum Phase: Equatable, Sendable {
        case restoring
        case signedOut
        case awaitingCode(email: String)
        case signedIn(userID: String, email: String?)
    }

    /// Flip once Apple is configured as a Supabase Auth provider.
    public static let appleSignInEnabled = false

    public private(set) var phase: Phase = .restoring
    public private(set) var isWorking = false
    public var errorMessage: String?
    /// Debug builds only: the keychain refused the session, so it is kept in
    /// memory for this run (the App Intent and Share Extension can't see it).
    public private(set) var sessionInMemoryOnly = false

    private let auth: AuthClient
    private let storage: SharedKeychainStorage?
    private var listener: Task<Void, Never>?

    public init(client: SupabaseClient, storage: SharedKeychainStorage? = nil) {
        auth = client.auth
        self.storage = storage
    }

    /// What a session event means once we know whether the session was saved.
    public enum Persistence: Equatable, Sendable {
        case saved
        /// Kept in memory (Debug fallback): usable in this process only.
        case memoryOnly
        case failed(OSStatus)
    }

    /// A sign-in whose session could not be saved is not a sign-in: every
    /// request would go out with the anon key. Pure, so it is unit-tested.
    public nonisolated static func phase(signedInAs userID: String, email: String?,
                                         persistence: Persistence) -> (phase: Phase, error: String?) {
        switch persistence {
        case .saved, .memoryOnly:
            return (.signedIn(userID: userID, email: email), nil)
        case .failed(let status):
            return (.signedOut, "Couldn't save your sign-in on this iPhone (keychain error \(status)). Try again; if it keeps failing, reinstall Ledger.")
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
            try await self.auth.signInWithOTP(email: trimmed, shouldCreateUser: true)
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
        await run { _ = try await self.auth.verifyOTP(email: email, token: digits, type: .email) }
    }

    /// Local development only (the seeded demo user). Not shown in Release.
    public func signIn(email: String, password: String) async {
        await run { _ = try await self.auth.signIn(email: email, password: password) }
    }

    public func cancelCode() {
        phase = .signedOut
        errorMessage = nil
    }

    public func signOut() async {
        await run { try await self.auth.signOut(scope: .local) }
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
        if error is URLError { return "No connection to Ledger." }
        return error.localizedDescription
    }

    public nonisolated static func isPlausibleEmail(_ s: String) -> Bool {
        s.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]{2,}$"#, options: .regularExpression) != nil
    }
}
