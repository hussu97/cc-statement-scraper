import LedgerKit
import SwiftUI

/// Wealth's Investments tab: the total the server values every holding at, the gain against what
/// went in and the last 24 hours, one period (30 days, 90 days, YTD, 365 days) for the value chart
/// and the returns, then a row per synced broker account (standing in for every holding it shows,
/// opening its portfolio), the other holdings grouped by kind, each opening its own screen, and the
/// live notes held anywhere else. Owners add a holding of any kind;
/// notes come from the broker sync. Every figure is the server's; what is listed is LedgerKit's
/// (`InvestmentsLayout`).
struct InvestmentsView: View {
    let model: InvestmentsModel
    let notes: NotesModel
    let profileCode: String
    let canEdit: Bool
    @State private var editing: HoldingDraft?
    /// A note opened from the notes card.
    @State private var openedNote: String?
    @Environment(AccountLedgers.self) private var ledgers

    var body: some View {
        Page {
            if let notice = model.notice ?? notes.notice {
                Label(notice.text, systemImage: notice.isError ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(Typography.rowMeta)
                    .foregroundStyle(notice.isError ? Palette.danger : Palette.positive)
                    .padding(.top, 8)
            }
            StateContainer(state: model.state, retry: reload) { content in
                InvestmentsHero(valuation: content.valuation)
                if !content.valuation.isEmpty {
                    Picker("Period", selection: Binding(
                        get: { model.period },
                        set: { period in Task { await model.select(period, profileCode: profileCode) } })) {
                        ForEach(ReturnsPeriod.investments) { Text($0.shortTitle).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    InvestmentsChartCard(model: model)
                    ReturnsCard(model: model, profileCode: profileCode)
                }
                let layout = content.layout
                holdings(content.valuation, layout)
                notesCard(layout)
            }
            .padding(.top, 8)
        }
        .rootNavigation("Investments")
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = model.newDraft() } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add holding")
                }
            }
        }
        .sheet(item: $editing) { draft in
            HoldingSheet(model: model, draft: draft, profileCode: profileCode, canEdit: canEdit)
        }
        .navigationDestination(item: $openedNote) { code in
            NoteDetailView(notes: notes, holdingCode: code, profileCode: profileCode, canEdit: canEdit)
        }
        .task { await model.loadIfNeeded(profileCode: profileCode) }
        .task { await notes.loadIfNeeded(profileCode: profileCode) }
        .refreshable {
            async let a: Void = model.load(profileCode: profileCode)
            async let b: Void = notes.load(profileCode: profileCode)
            _ = await (a, b)
        }
        .onDisappear {
            model.notice = nil
            notes.notice = nil
        }
    }

    @ViewBuilder private func holdings(_ valuation: HoldingsValuation, _ layout: InvestmentsLayout) -> some View {
        if !layout.brokerRows.isEmpty {
            Card {
                SectionHeader(title: "Broker accounts")
                ForEach(layout.brokerRows) { row in
                    if row.id != layout.brokerRows.first?.id { Divider().overlay(Palette.border) }
                    NavigationLink {
                        AccountLedgerView(model: ledgers.model(for: row.accountCode), profileCode: profileCode, canEdit: canEdit,
                                          showsPortfolio: true)
                    } label: {
                        BrokerAccountLine(row: row)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the account's portfolio")
                }
            }
        }
        if layout.isEmpty {
            Card {
                SectionHeader(title: "Holdings")
                Text(HoldingsValuation.emptyMessage(canEdit: canEdit, onlyNotes: valuation.onlyNotes))
                    .font(Typography.rowMeta).foregroundStyle(Palette.muted)
                if canEdit {
                    Button("Add holding") { editing = model.newDraft() }
                        .buttonStyle(.bordered).tint(Palette.accent)
                }
            }
        }
        ForEach(layout.groups) { group in
            Card {
                SectionHeader(title: group.title, trailing: group.countText)
                ForEach(group.holdings) { holding in
                    if holding.id != group.holdings.first?.id { Divider().overlay(Palette.border) }
                    NavigationLink {
                        if holding.kind == .structuredNote {
                            NoteDetailView(notes: notes, holdingCode: holding.holdingCode, profileCode: profileCode,
                                           canEdit: canEdit)
                        } else {
                            HoldingDetailView(investments: model, holdingCode: holding.holdingCode,
                                              profileCode: profileCode, canEdit: canEdit)
                        }
                    } label: {
                        HoldingRow(holding: holding)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the holding's money in and out, values and returns")
                }
            }
        }
    }

    /// The live notes no broker account shows; nothing while they load or when there are none.
    @ViewBuilder private func notesCard(_ layout: InvestmentsLayout) -> some View {
        if let rows = notes.liveRows(excluding: layout.brokerHoldings) {
            if !rows.isEmpty { NotesCard(rows: rows) { openedNote = $0 } }
        } else if let error = notes.state.errorMessage {
            FailedCard(message: error) { Task { await notes.load(profileCode: profileCode) } }
        }
    }

    private func reload() { Task { await model.load(profileCode: profileCode) } }
}

/// A synced broker account standing in for its holdings: name, AED value (its own currency under
/// it), profit, live notes and the 24-hour move.
private struct BrokerAccountLine: View {
    let row: BrokerAccountRow

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            AdaptiveRow(alignment: .center) {
                HStack(spacing: 10) {
                    if let bank = row.bankCode { BankLogo(bankCode: bank, size: 28) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                        Text(row.detail).font(Typography.caption)
                            .foregroundStyle(row.syncFailed ? Palette.warn : row.profitTone.color)
                        if let change = row.changeText {
                            Text(change).font(Typography.caption).foregroundStyle(row.changeTone.color)
                        }
                    }
                }
            } trailing: {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(row.valueText).font(Typography.amount).foregroundStyle(Palette.ink).monospacedDigit().fixedSize()
                    if let own = row.ownText {
                        Text(own).font(Typography.caption).foregroundStyle(Palette.muted).monospacedDigit().fixedSize()
                    }
                }
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }
}

/// The total, the gain against cost and the last 24 hours, and what the figures leave out.
private struct InvestmentsHero: View {
    let valuation: HoldingsValuation
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize = Typography.heroBaseSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                Text("ALL HOLDINGS").font(Typography.caption).tracking(1.2).foregroundStyle(Palette.muted)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("AED").font(Typography.heroUnit).foregroundStyle(Palette.muted)
                    Text(valuation.heroAmount).font(Typography.hero(size: heroSize)).foregroundStyle(Palette.ink)
                        .lineLimit(1).minimumScaleFactor(0.4)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(valuation.heroAccessibilityLabel)
            VStack(alignment: .leading, spacing: 4) {
                if let cost = valuation.costAed { line("Put in", MoneyFormat.aed(cost), Palette.ink) }
                line("Gain", valuation.gainText ?? "Add what you paid", valuation.gainText == nil ? Palette.muted
                                                                                                : valuation.gainTone.color)
                if let change = valuation.changeText { line("Last 24 hours", change, valuation.changeTone.color) }
            }
            ForEach(valuation.caveats, id: \.self) { caveat in
                Label(caveat, systemImage: "exclamationmark.triangle")
                    .font(Typography.caption).foregroundStyle(Palette.warn)
            }
        }
    }

    private func line(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(Typography.rowMeta).foregroundStyle(Palette.muted)
            Spacer()
            Text(value).font(Typography.amount).foregroundStyle(color).moneyLine()
        }
        .accessibilityElement(children: .combine)
    }
}
