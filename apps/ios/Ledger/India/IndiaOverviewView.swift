import LedgerKit
import SwiftUI

/// India mode's Overview: every Zerodha Kite and Coin account in rupees (AED under), what went in,
/// the P&L and the last 24 hours; one period (30 days, 90 days, YTD, 365 days) for the value chart
/// and the period's growth; then a row per account opening its tab. Every figure is
/// `india_overview`'s; the words are LedgerKit's (`IndiaHero`, `IndiaAccountRow`, `IndiaPeriod`).
struct IndiaOverviewView: View {
    let model: IndiaModel
    let profileCode: String
    @Environment(TabRouter.self) private var tabs

    var body: some View {
        Page {
            StateContainer(state: model.state, retry: reload) { overview in
                if overview.available {
                    IndiaHeroView(hero: IndiaHero(overview))
                    Picker("Period", selection: Binding(
                        get: { model.period },
                        set: { period in Task { await model.select(period, profileCode: profileCode) } })) {
                        ForEach(ReturnsPeriod.investments) { Text($0.shortTitle).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    IndiaChartCard(model: model)
                    IndiaPeriodCard(model: model, profileCode: profileCode)
                    accounts(IndiaText.rows(overview))
                } else {
                    EmptyCard(systemImage: "indianrupeesign", message: IndiaText.unavailableMessage)
                }
            }
            .padding(.top, 8)
        }
        .rootNavigation("India")
        .task { await model.loadIfNeeded(profileCode: profileCode) }
        .refreshable { await model.load(profileCode: profileCode) }
    }

    @ViewBuilder private func accounts(_ rows: [IndiaAccountRow]) -> some View {
        if !rows.isEmpty {
            Card {
                SectionHeader(title: "Accounts")
                ForEach(rows) { row in
                    if row.id != rows.first?.id { Divider().overlay(Palette.border) }
                    if let tab = row.tab {
                        Button { tabs.show(tab) } label: { IndiaAccountLine(row: row, opens: true) }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens the account's portfolio")
                    } else {
                        IndiaAccountLine(row: row, opens: false)
                    }
                }
            }
        }
    }

    private func reload() { Task { await model.load(profileCode: profileCode) } }
}

/// One account: logo, name, P&L and positions, the 24-hour move; rupees with AED under.
private struct IndiaAccountLine: View {
    let row: IndiaAccountRow
    let opens: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            AdaptiveRow(alignment: .center) {
                HStack(spacing: 10) {
                    if let bank = row.bankCode { BankLogo(bankCode: bank, size: 28) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                        if !row.detail.isEmpty {
                            Text(row.detail).font(Typography.caption).foregroundStyle(row.detailTone.color)
                        }
                        if let change = row.changeText {
                            Text(change).font(Typography.caption).foregroundStyle(row.changeTone.color)
                        }
                    }
                }
            } trailing: {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(row.valueText).font(Typography.amount).foregroundStyle(Palette.ink).monospacedDigit().fixedSize()
                    if let aed = row.aedText {
                        Text(aed).font(Typography.caption).foregroundStyle(Palette.muted).monospacedDigit().fixedSize()
                    }
                }
            }
            if opens { Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted) }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }
}

/// The total in rupees, AED under it, then invested, P&L, cash and the last 24 hours.
private struct IndiaHeroView: View {
    let hero: IndiaHero
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize = Typography.heroBaseSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text("KITE AND COIN").font(Typography.caption).tracking(1.2).foregroundStyle(Palette.muted)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(hero.currency).font(Typography.heroUnit).foregroundStyle(Palette.muted)
                    Text(hero.amount).font(Typography.hero(size: heroSize)).foregroundStyle(Palette.ink)
                        .lineLimit(1).minimumScaleFactor(0.4)
                }
                if let aed = hero.aedText {
                    Text(aed).font(Typography.rowMeta).foregroundStyle(Palette.muted).monospacedDigit()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(hero.accessibilityLabel)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(hero.lines) { line in
                    HStack(alignment: .firstTextBaseline) {
                        Text(line.label).font(Typography.rowMeta).foregroundStyle(Palette.muted)
                        Spacer()
                        Text(line.text).font(Typography.amount).moneyLine()
                            .foregroundStyle(line.tone == .neutral ? Palette.ink : line.tone.color)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if let sync = hero.syncText {
                Label(sync, systemImage: "arrow.triangle.2.circlepath")
                    .font(Typography.caption).foregroundStyle(Palette.muted)
            }
        }
    }
}
