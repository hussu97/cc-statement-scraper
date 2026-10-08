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

    private let auth: AuthClient
    private var listener: Task<Void, Never>?

    public init(client: SupabaseClient) {
        auth = client.auth
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
                        self.phase = .signedIn(userID: session.user.id.uuidString.lowercased(), email: session.user.email)
                        Telemetry.setUser(id: session.user.id.uuidString.lowercased())
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
