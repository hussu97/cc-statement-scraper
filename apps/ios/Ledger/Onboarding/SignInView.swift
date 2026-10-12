import LedgerKit
import SwiftUI

/// Sign in with an emailed one-time code or a passkey. "Sign in with a password"
/// is for the App Review demo account, the only production account with one.
struct SignInView: View {
    let session: SessionStore
    @State private var email = ""
    @State private var code = ""
    @State private var password = ""
    @State private var usesPassword = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bank Ledger").font(.system(size: 44, weight: .regular, design: .serif))
                    Text("Every card, every dirham — from SMS and statements, reconciled.")
                        .font(Typography.body)
                        .foregroundStyle(Palette.muted)
                }
                .padding(.top, 48)

                switch session.phase {
                case .awaitingCode(let address):
                    codeForm(address)
                default:
                    if usesPassword {
                        passwordForm
                    } else {
                        emailForm
                        passkeyButton
                        Button("Sign in with a password") {
                            session.errorMessage = nil
                            usesPassword = true
                        }
                        .font(Typography.rowMeta)
                        .frame(maxWidth: .infinity)
                        .disabled(session.isWorking)
                    }
                }

                if let error = session.errorMessage {
                    Text(error).font(Typography.rowMeta).foregroundStyle(Palette.danger)
                }
            }
            .padding(Metrics.gutter)
        }
        .background(Palette.bg)
    }

    private var emailForm: some View {
        Card {
            Text("Sign in with your email").font(Typography.cardTitle)
            Text("We'll email you a one-time code.").font(Typography.rowMeta).foregroundStyle(Palette.muted)
            TextField("you@example.com", text: $email)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .onSubmit { Task { await session.sendCode(to: email) } }
                .padding(12)
                .background(Palette.surface2, in: RoundedRectangle(cornerRadius: Metrics.radiusMd))
            Button {
                Task { await session.sendCode(to: email) }
            } label: {
                Text(session.isWorking ? "Sending…" : "Email me a code").frame(maxWidth: .infinity, minHeight: Metrics.tapMin)
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.isWorking || email.isEmpty)
        }
    }

    private var passkeyButton: some View {
        Button {
            guard let anchor = PresentationAnchor.current else { return }
            Task { await session.signInWithPasskey(anchor: anchor) }
        } label: {
            Label("Sign in with a passkey", systemImage: "person.badge.key")
                .frame(maxWidth: .infinity, minHeight: Metrics.tapMin)
        }
        .buttonStyle(.bordered)
        .disabled(session.isWorking)
    }

    private var passwordForm: some View {
        Card {
            Text("Sign in with a password").font(Typography.cardTitle)
            TextField("you@example.com", text: $email)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(Palette.surface2, in: RoundedRectangle(cornerRadius: Metrics.radiusMd))
            SecureField("Password", text: $password)
                .textContentType(.password)
                .submitLabel(.go)
                .onSubmit { Task { await session.signIn(email: email, password: password) } }
                .padding(12)
                .background(Palette.surface2, in: RoundedRectangle(cornerRadius: Metrics.radiusMd))
            Button {
                Task { await session.signIn(email: email, password: password) }
            } label: {
                Text(session.isWorking ? "Signing in…" : "Sign in").frame(maxWidth: .infinity, minHeight: Metrics.tapMin)
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.isWorking || !SessionStore.canSubmitPassword(email: email, password: password))
            Button("Use an email code instead") {
                password = ""
                session.errorMessage = nil
                usesPassword = false
            }
            .font(Typography.rowMeta)
        }
    }

    private func codeForm(_ address: String) -> some View {
        Card {
            Text("Enter the code sent to \(address)").font(Typography.cardTitle)
            Text("It expires in an hour.").font(Typography.rowMeta).foregroundStyle(Palette.muted)
            TextField("123456", text: $code)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .font(.system(.title2, design: .monospaced))
                .padding(12)
                .background(Palette.surface2, in: RoundedRectangle(cornerRadius: Metrics.radiusMd))
            Button {
                Task { await session.verify(code: code) }
            } label: {
                Text(session.isWorking ? "Checking…" : "Sign in").frame(maxWidth: .infinity, minHeight: Metrics.tapMin)
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.isWorking || code.filter(\.isNumber).count < 6)
            HStack {
                Button("Use a different email") {
                    code = ""
                    session.cancelCode()
                }
                Spacer()
                Button("Send a new code") { Task { await session.sendCode(to: address) } }
                    .disabled(session.isWorking)
            }
            .font(Typography.rowMeta)
        }
    }
}

/// Shown right after an email-code sign-in when the account has no passkey.
struct PasskeyOfferView: View {
    let session: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if case .offering = session.passkeyOffer {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)
                Text("Add a passkey?").font(.system(size: 34, weight: .regular, design: .serif))
                Text("Next time, sign in with Face ID instead of waiting for an email code. The passkey is saved in your iCloud Keychain, so it also works on your other Apple devices and on the Bank Ledger website.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.muted)
                if let error = session.passkeys.errorMessage {
                    Text(error).font(Typography.rowMeta).foregroundStyle(Palette.danger)
                }
                Button {
                    guard let anchor = PresentationAnchor.current else { return }
                    Task { await session.acceptPasskeyOffer(anchor: anchor) }
                } label: {
                    Text(session.passkeys.isWorking ? "Adding…" : "Add a passkey").frame(maxWidth: .infinity, minHeight: Metrics.tapMin)
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.passkeys.isWorking)
                Button("Not now") { session.declinePasskeyOffer() }
                    .frame(maxWidth: .infinity)
                    .disabled(session.passkeys.isWorking)
                Text("You can add or remove passkeys any time in Settings.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.muted)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .padding(Metrics.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.bg)
    }
}

/// The key window, for the native passkey sheet.
enum PresentationAnchor {
    @MainActor static var current: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
}
