import LedgerKit
import SwiftUI

/// Email one-time code sign-in. Sign in with Apple appears once
/// `SessionStore.appleSignInEnabled` is turned on.
struct SignInView: View {
    let session: SessionStore
    @State private var email = ""
    @State private var code = ""
    #if DEBUG
    @State private var password = ""
    @State private var showPassword = false
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ledger").font(.system(size: 44, weight: .regular, design: .serif))
                    Text("Every card, every dirham — from SMS and statements, reconciled.")
                        .font(Typography.body)
                        .foregroundStyle(Palette.muted)
                }
                .padding(.top, 48)

                switch session.phase {
                case .awaitingCode(let address):
                    codeForm(address)
                default:
                    emailForm
                }

                if let error = session.errorMessage {
                    Text(error).font(Typography.rowMeta).foregroundStyle(Palette.danger)
                }

                if SessionStore.appleSignInEnabled {
                    Button {} label: { Label("Sign in with Apple", systemImage: "apple.logo") }
                        .buttonStyle(.bordered)
                        .disabled(true)
                }

                #if DEBUG
                devPasswordForm
                #endif
            }
            .padding(Metrics.gutter)
        }
        .background(Palette.bg)
    }

    private var emailForm: some View {
        Card {
            Text("Sign in with your email").font(Typography.cardTitle)
            TextField("you@example.com", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
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

    private func codeForm(_ address: String) -> some View {
        Card {
            Text("Enter the code sent to \(address)").font(Typography.cardTitle)
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
            .disabled(session.isWorking || code.isEmpty)
            Button("Use a different email") { session.cancelCode() }
                .font(Typography.rowMeta)
        }
    }

    #if DEBUG
    private var devPasswordForm: some View {
        DisclosureGroup("Developer: password sign-in", isExpanded: $showPassword) {
            VStack(spacing: 8) {
                TextField("email", text: $email)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("password", text: $password)
                Button("Sign in") { Task { await session.signIn(email: email, password: password) } }
                    .buttonStyle(.bordered)
            }
            .padding(.top, 8)
        }
        .font(Typography.caption)
        .foregroundStyle(Palette.muted)
    }
    #endif
}
