import LedgerKit
import SwiftUI

/// "Sign out": when SMS, card payments or PDFs are still waiting on this phone,
/// a confirmation that names them first, since signing out deletes exactly
/// those (BACKLOG IOS-12r). The counting, the order and the cleanup are `AppModel`'s.
struct SignOutButton: View {
    let model: AppModel
    @State private var plan: SignOutPlan?
    @State private var isSigningOut = false

    var body: some View {
        Button("Sign out", role: .destructive) {
            Task {
                isSigningOut = true
                defer { isSigningOut = false }
                let counted = await model.prepareSignOut()
                if counted.warning != nil {
                    plan = counted
                } else {
                    await model.signOut(deleting: counted)
                }
            }
        }
        .disabled(isSigningOut)
        .confirmationDialog("Sign out?", isPresented: Binding(
            get: { plan != nil }, set: { if !$0 { plan = nil } }),
                            titleVisibility: .visible, presenting: plan) { counted in
            Button("Sign out and delete", role: .destructive) { Task { await model.signOut(deleting: counted) } }
            Button("Cancel", role: .cancel) {}
        } message: { counted in
            Text(counted.warning ?? "")
        }
    }
}
