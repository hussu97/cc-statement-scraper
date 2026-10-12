import LedgerKit
import SwiftUI

/// "Sign out": when SMS or PDFs are still waiting on this phone, a confirmation
/// that names them first, since signing out deletes them (BACKLOG IOS-12r). The
/// wording and the cleanup are `AppModel`'s.
struct SignOutButton: View {
    let model: AppModel
    @State private var warning: String?
    @State private var isSigningOut = false

    var body: some View {
        Button("Sign out", role: .destructive) {
            Task {
                isSigningOut = true
                defer { isSigningOut = false }
                if let text = await model.signOutWarning() {
                    warning = text
                } else {
                    await model.signOut()
                }
            }
        }
        .disabled(isSigningOut)
        .confirmationDialog("Sign out?", isPresented: Binding(
            get: { warning != nil }, set: { if !$0 { warning = nil } }),
                            titleVisibility: .visible, presenting: warning) { _ in
            Button("Sign out and delete", role: .destructive) { Task { await model.signOut() } }
            Button("Cancel", role: .cancel) {}
        } message: { text in
            Text(text)
        }
    }
}
