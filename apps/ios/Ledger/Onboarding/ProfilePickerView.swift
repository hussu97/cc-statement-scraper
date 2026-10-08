import LedgerKit
import SwiftUI

/// Choose (or create) the ledger the app and the SMS automation post to.
struct ProfilePickerView: View {
    let profiles: ProfileStore
    var onSignOut: () -> Void
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            Page {
                Text("Choose a ledger").font(Typography.display).padding(.top, 8)
                StateContainer(state: profiles.state, retry: { Task { await profiles.load() } }) { list in
                    if list.isEmpty {
                        EmptyCard(systemImage: "tray", message: "You don't have a ledger yet. Create one below.")
                    } else {
                        Card(padding: 0) {
                            ForEach(list) { profile in
                                Button {
                                    profiles.select(profile.profileCode)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(profile.name).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                                            Text(profile.baseCurrency).font(Typography.rowMeta).foregroundStyle(Palette.muted)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").foregroundStyle(Palette.subtle)
                                    }
                                    .padding(Metrics.gutter)
                                }
                                if profile.id != list.last?.id { Divider().overlay(Palette.border) }
                            }
                        }
                    }
                }
                Card {
                    Text("New ledger").font(Typography.cardTitle)
                    TextField("Name, e.g. Household", text: $newName)
                        .padding(12)
                        .background(Palette.surface2, in: RoundedRectangle(cornerRadius: Metrics.radiusMd))
                    Button("Create") { Task { await profiles.create(name: newName) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let error = profiles.errorMessage {
                        Text(error).font(Typography.caption).foregroundStyle(Palette.danger)
                    }
                }
                Button("Sign out", role: .destructive, action: onSignOut).font(Typography.rowMeta)
            }
            .ledgerNavigation("")
        }
    }
}
