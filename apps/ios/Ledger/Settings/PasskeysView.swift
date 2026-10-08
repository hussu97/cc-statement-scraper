import LedgerKit
import SwiftUI

/// Settings → Passkeys: list, add, rename and remove the account's passkeys.
struct PasskeysView: View {
    let session: SessionStore
    @State private var renaming: LedgerPasskey?
    @State private var newName = ""
    @State private var removing: LedgerPasskey?

    private var store: PasskeyStore { session.passkeys }

    var body: some View {
        List {
            Section {
                switch store.state {
                case .idle, .loading(previous: nil):
                    ProgressView()
                case .failed(let message, previous: nil):
                    Text(message).foregroundStyle(Palette.danger)
                    Button("Try again") { Task { await store.load() } }
                default:
                    let list = store.state.value ?? []
                    if list.isEmpty {
                        Text("No passkeys yet. Add one to skip the email code next time.")
                            .foregroundStyle(Palette.muted)
                    }
                    ForEach(list) { passkey in
                        PasskeyRow(passkey: passkey)
                            .swipeActions {
                                Button("Remove", role: .destructive) { removing = passkey }
                                Button("Rename") {
                                    newName = passkey.name
                                    renaming = passkey
                                }
                            }
                            .contextMenu {
                                Button("Rename", systemImage: "pencil") {
                                    newName = passkey.name
                                    renaming = passkey
                                }
                                Button("Remove", systemImage: "trash", role: .destructive) { removing = passkey }
                            }
                    }
                }
            } footer: {
                Text("Passkeys let you sign in with Face ID instead of an email code. They're saved in iCloud Keychain and also work on the Bank Ledger website.")
            }

            Section {
                Button {
                    guard let anchor = PresentationAnchor.current else { return }
                    Task {
                        if await store.add(anchor: anchor), case .signedIn(let id, _) = session.phase {
                            store.setOfferDeclined(false, userID: id)
                        }
                    }
                } label: {
                    HStack {
                        Label("Add a passkey", systemImage: "plus")
                        if store.isWorking { Spacer(); ProgressView() }
                    }
                }
                .disabled(store.isWorking)
                if let error = store.errorMessage {
                    Text(error).font(Typography.caption).foregroundStyle(Palette.danger)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.bg)
        .ledgerNavigation("Passkeys")
        .task { await store.load() }
        .refreshable { await store.load() }
        .alert("Rename passkey", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                if let passkey = renaming { Task { await store.rename(passkey.id, to: newName) } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Remove this passkey?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove passkey", role: .destructive) {
                if let passkey = removing { Task { await store.remove(passkey.id) } }
            }
        } message: {
            Text("It will no longer sign you in to Bank Ledger. You can still sign in with an email code. Also delete it from Passwords so it isn't offered again.")
        }
    }
}

private struct PasskeyRow: View {
    let passkey: LedgerPasskey

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(passkey.name)
            Text(detail).font(Typography.caption).foregroundStyle(Palette.muted)
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let added = "Added \(passkey.createdAt.formatted(date: .abbreviated, time: .omitted))"
        guard let used = passkey.lastUsedAt else { return "\(added) · not used yet" }
        return "\(added) · last used \(used.formatted(.relative(presentation: .named)))"
    }
}
