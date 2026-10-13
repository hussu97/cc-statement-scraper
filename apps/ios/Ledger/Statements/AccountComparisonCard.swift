import LedgerKit
import SwiftUI

/// Compare accounts (PAR-13, the web's Cards → `AccountComparison`): per account, statement
/// balance, utilisation and monthly spending, each with its latest server value and a small
/// sparkline. `AccountComparisonModel` shapes and words it; this lays it out.
struct AccountComparisonCard: View {
    let model: AccountComparisonModel
    let retry: () -> Void

    var body: some View {
        if model.isVisible {
            Card {
                SectionHeader(title: "Compare accounts")
                if model.accounts.value == nil {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 64)
                } else {
                    ForEach(model.rows) { row in
                        AccountComparisonRow(model: model, row: row, retry: retry)
                        if row.id != model.rows.last?.id { Divider().overlay(Palette.border) }
                    }
                }
                Text(AccountComparison.footnote).font(Typography.caption).foregroundStyle(Palette.muted)
            }
        }
    }
}

private struct AccountComparisonRow: View {
    let model: AccountComparisonModel
    let row: AccountComparisonModel.Row
    let retry: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                BankLogo(bankCode: row.account.bankCode, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.account.label).font(Typography.rowTitle).foregroundStyle(Palette.ink).lineLimit(1)
                    if !row.account.isActive, let status = row.account.status {
                        Text(status.capitalized).font(Typography.caption).foregroundStyle(Palette.muted)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                                count: typeSize.isAccessibilitySize ? 1 : 3)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                statementCell { model.balanceCell(row) }
                statementCell { model.utilisationCell(row) }
                cell(state: model.spending.value == nil ? model.spending.errorMessage : nil,
                     failed: "Couldn't load spending", loading: model.spending.value == nil) { model.spendingCell(row) }
            }
        }
        .padding(.vertical, 2)
    }

    private func statementCell(_ make: () -> AccountComparison.Cell) -> some View {
        cell(state: model.statements.value == nil ? model.statements.errorMessage : nil,
             failed: "Couldn't load statements", loading: model.statements.value == nil, make)
    }

    @ViewBuilder
    private func cell(state error: String?, failed: String, loading: Bool,
                      _ make: () -> AccountComparison.Cell) -> some View {
        if let error {
            VStack(alignment: .leading, spacing: 4) {
                Text(failed).font(Typography.caption).foregroundStyle(Palette.danger)
                Button("Retry", action: retry).font(Typography.caption).accessibilityHint(error)
            }
        } else if loading {
            ProgressView().frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        } else {
            ComparisonCellView(cell: make(), color: ChartPalette.color(for: row.colorToken))
        }
    }
}

private struct ComparisonCellView: View {
    let cell: AccountComparison.Cell
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(cell.label).font(Typography.caption).foregroundStyle(Palette.muted).lineLimit(1)
            Text(cell.value).font(Typography.rowMeta.weight(.semibold)).foregroundStyle(Palette.ink)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Group {
                if let spark = cell.spark, !spark.isEmpty {
                    SparklineView(spark: spark, color: color)
                } else {
                    // No line to draw: a dashed baseline, as on the web.
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: 31))
                        p.addLine(to: CGPoint(x: 400, y: 31))
                    }
                    .stroke(Palette.border, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .clipped()
                }
            }
            .frame(height: 32)
            Text(cell.caption).font(Typography.caption).foregroundStyle(Palette.muted).lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cell.accessibilityLabel)
    }
}

/// Draws `Sparkline`'s unit-box segments inside the frame, with an end marker.
private struct SparklineView: View {
    let spark: Sparkline
    let color: Color
    private let inset: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - inset * 2
            let h = geo.size.height - inset * 2
            let place = { (p: Sparkline.Point) in CGPoint(x: inset + p.x * w, y: inset + p.y * h) }
            ZStack {
                Path { path in
                    for segment in spark.segments where segment.count > 1 {
                        path.move(to: place(segment[0]))
                        for point in segment.dropFirst() { path.addLine(to: place(point)) }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                // A lone point between gaps, and the latest value: dots.
                ForEach(Array(spark.segments.enumerated()), id: \.offset) { _, segment in
                    if segment.count == 1 { Circle().fill(color).frame(width: 3, height: 3).position(place(segment[0])) }
                }
                if let last = spark.last {
                    Circle().fill(color).frame(width: 5, height: 5).position(place(last))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
