import LedgerKit
import SwiftUI

/// Open reviews for the active ledger: link an SMS or statement line to a
/// candidate, keep it as a new transaction, register an unknown card, or
/// dismiss. What each review offers is decided in LedgerKit (`ReviewPresentation`).
struct ReviewView: View {
    let model: ReviewModel
    let profileCode: String
    let canResolve: Bool

    var body: some View {
        Page {
            if let message = model.message {
                Label(message, systemImage: "checkmark.circle")
                    .font(Typography.rowMeta).foregroundStyle(Palette.muted)
                    .padding(.top, 8)
            }
            if !canResolve {
                Text("You're a viewer on this ledger. Only its owners can resolve reviews.")
                    .font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
            StateContainer(state: model.state, retry: reload) { groups in
                if groups.isEmpty {
                    EmptyCard(systemImage: "checkmark.seal", message: "Nothing to review.")
                }
                ForEach(groups) { group in
                    ReviewGroupCard(group: group, working: model.working, canResolve: canResolve) { item, option in
                        Task { await model.resolve(item, option, profileCode: profileCode) }
                    }
                }
                if !groups.isEmpty {
                    PagingFooter(footer: model.footer, endMessage: model.endMessage) { await model.loadMore() }
                }
            }
        }
        .ledgerNavigation("Review")
        .task { await model.open(profileCode: profileCode) }
        .refreshable { await model.load(profileCode: profileCode) }
    }

    private func reload() { Task { await model.load(profileCode: profileCode) } }
}

private struct ReviewGroupCard: View {
    let group: ReviewGroup
    let working: String?
    let canResolve: Bool
    let resolve: (ReviewItem, ReviewItem.Option) -> Void

    var body: some View {
        Card {
            SectionHeader(title: group.title, trailing: "\(group.items.count)")
            Text(group.help).font(Typography.caption).foregroundStyle(Palette.muted)
            ForEach(group.items) { item in
                Divider().overlay(Palette.border)
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.subject).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                    if let detail = item.subjectDetail {
                        Text(detail).font(Typography.caption).foregroundStyle(Palette.muted)
                    }
                    if let note = item.note {
                        Text(note).font(Typography.caption).foregroundStyle(Palette.muted)
                    }
                    if canResolve {
                        if working == item.id {
                            ProgressView()
                        } else {
                            ForEach(item.options) { option in
                                Button(role: option.isDestructive ? .destructive : nil) {
                                    resolve(item, option)
                                } label: {
                                    Text(option.label)
                                        .font(Typography.rowMeta)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, minHeight: Metrics.tapMin, alignment: .leading)
                                }
                                .buttonStyle(.bordered)
                                .tint(option.isDestructive ? Palette.muted : Palette.accent)
                            }
                        }
                    }
                }
            }
        }
    }
}
