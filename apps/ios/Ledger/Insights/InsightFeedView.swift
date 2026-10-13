import LedgerKit
import SwiftUI

/// "Worth a look" (PAR-9, the web's Insights → Worth a look): every open insight in sections by
/// the screen that answers it, each linking there. Owners dismiss one. Sections, order and links
/// are decided in LedgerKit (`InsightFeed`, `InsightLink`).
struct InsightFeedView: View {
    let profileCode: String
    /// Owners only (RLS `insights_owner_dismiss`).
    let canDismiss: Bool
    /// The tab this screen is pushed on: an Insights link goes back rather than switching tab.
    let host: LedgerTab
    @Environment(InsightFeedModel.self) private var feed

    var body: some View {
        Page {
            StateContainer(state: feed.state, retry: reload) { _ in
                let groups = feed.groups ?? []
                if groups.isEmpty {
                    Card {
                        Label("All quiet", systemImage: "lightbulb").font(Typography.cardTitle).foregroundStyle(Palette.ink)
                        Text("Bank Ledger checks your spending every night: pace, category spikes, large charges, budgets, price changes, statements due and anything left to tidy up. Whatever needs a look appears here.")
                            .font(Typography.rowMeta).foregroundStyle(Palette.muted)
                    }
                }
                ForEach(groups) { group in
                    Card {
                        SectionHeader(title: group.label, trailing: group.countLabel)
                        ForEach(group.items) { insight in
                            if insight.id != group.items.first?.id { Divider().overlay(Palette.border) }
                            InsightRow(insight: insight, link: feed.link(for: insight), host: host,
                                       profileCode: profileCode, showAge: true,
                                       dismiss: canDismiss ? { Task { await feed.dismiss(insight, profileCode: profileCode) } } : nil)
                        }
                    }
                }
                if let note = feed.limitNote {
                    Text(note).font(Typography.caption).foregroundStyle(Palette.muted)
                }
            }
            .padding(.top, 8)
        }
        .ledgerNavigation("Worth a look")
        .navigationBarTitleDisplayMode(.inline)
        .task { await feed.loadIfNeeded(profileCode: profileCode) }
        .refreshable { await feed.load(profileCode: profileCode) }
    }

    private func reload() { Task { await feed.load(profileCode: profileCode) } }
}

/// One insight: severity mark, title, body, where it leads and (in the feed) when it was
/// noticed; an owner's dismiss button. Shared by the feed and Overview's card.
struct InsightRow: View {
    let insight: Insight
    let link: InsightLink?
    let host: LedgerTab
    let profileCode: String
    var showAge = false
    /// Nil when the user may not dismiss (not an owner).
    let dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(insight.tone.color).frame(width: 3)
                .accessibilityLabel(insight.severityLabel)
            InsightLinkButton(link: link, host: host, profileCode: profileCode) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(insight.title).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                    Text(insight.body).font(Typography.rowMeta).foregroundStyle(Palette.muted)
                    HStack(spacing: 12) {
                        if let link {
                            Label(link.label, systemImage: "arrow.right").labelStyle(TitleThenIcon())
                                .font(Typography.caption).foregroundStyle(Palette.accent)
                        }
                        if showAge {
                            Text(insight.noticedLabel()).font(Typography.caption).foregroundStyle(Palette.muted)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.caption).frame(minWidth: Metrics.tapMin, minHeight: Metrics.tapMin)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.muted)
                .accessibilityLabel("Dismiss: \(insight.title)")
            }
        }
    }
}

/// Follows an insight's link: a category's drill-down is pushed here; an Insights link from a
/// screen pushed on Insights goes back to it; everything else switches tab (`TabRouter.follow`).
struct InsightLinkButton<Label: View>: View {
    let link: InsightLink?
    let host: LedgerTab
    let profileCode: String
    @ViewBuilder var label: Label
    @Environment(TabRouter.self) private var tabs: TabRouter?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        switch link {
        case .none:
            label
        case .category(let request)?:
            NavigationLink {
                CategoryDetailView(request: request, profileCode: profileCode)
            } label: { label }
                .buttonStyle(.plain)
                .accessibilityHint("See the category")
        case let link?:
            Button {
                if link.opensInsights && host == .insights { dismiss() } else { tabs?.follow(link) }
            } label: { label }
                .buttonStyle(.plain)
                .accessibilityHint(link.label)
        }
    }
}

/// `See budgets →`: title first, icon after.
private struct TitleThenIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.font(.caption2.weight(.semibold))
        }
    }
}
