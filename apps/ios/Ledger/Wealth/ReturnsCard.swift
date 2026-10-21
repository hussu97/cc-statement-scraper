import LedgerKit
import SwiftUI

/// Investments' returns for a period (All / This year / 12 months): money added kept apart from
/// growth, income, the simple return and the money-weighted yearly rate, and which holdings the
/// total leaves out for want of a start value. Every figure is the server's (`holding_returns`).
struct ReturnsCard: View {
    let model: InvestmentsModel
    let profileCode: String

    var body: some View {
        Card {
            SectionHeader(title: "Returns", trailing: model.selectedReturns.value?.rangeText)
            Picker("Period", selection: Binding(
                get: { model.returnsPeriod },
                set: { period in Task { await model.selectReturns(period, profileCode: profileCode) } })) {
                ForEach(ReturnsPeriod.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            switch model.selectedReturns {
            case .failed(let message, nil):
                Text(message).font(Typography.caption).foregroundStyle(Palette.danger)
                Button("Try again") {
                    Task { await model.selectReturns(model.returnsPeriod, profileCode: profileCode) }
                }
                .buttonStyle(.bordered).tint(Palette.accent)
            default:
                if let returns = model.selectedReturns.value {
                    ReturnFiguresView(figures: returns.total, period: model.returnsPeriod)
                    if let note = returns.incompleteNote {
                        Label(note, systemImage: "exclamationmark.triangle")
                            .font(Typography.caption).foregroundStyle(Palette.warn)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                }
            }
        }
    }
}

/// A period's lines (start, added, income, now, growth, return) and the yearly rate.
struct ReturnFiguresView: View {
    let figures: ReturnFigures
    let period: ReturnsPeriod

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(figures.lines(period: period)) { line in
                HStack(alignment: .firstTextBaseline) {
                    Text(line.label).font(Typography.rowMeta).foregroundStyle(Palette.muted)
                    Spacer()
                    Text(line.text).font(Typography.amount).moneyLine()
                        .foregroundStyle(line.tone == .neutral ? Palette.ink : line.tone.color)
                }
                .accessibilityElement(children: .combine)
            }
            Divider().overlay(Palette.border)
            HStack(alignment: .firstTextBaseline) {
                Text(ReturnFigures.annualLabel).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                Spacer()
                Text(figures.annualText ?? "–").font(Typography.amount).moneyLine()
                    .foregroundStyle(figures.annualText == nil ? Palette.muted : figures.annualTone.color)
            }
            .accessibilityElement(children: .combine)
            Text(figures.annualText == nil ? ReturnFigures.noAnnualNote : ReturnFigures.annualNote)
                .font(Typography.caption).foregroundStyle(Palette.muted)
        }
    }
}
