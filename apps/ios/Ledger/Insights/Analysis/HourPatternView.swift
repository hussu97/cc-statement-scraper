import LedgerKit
import SwiftUI

/// When you spend: an hour × weekday heatmap (web Insights › Time of day, BACKLOG PAR-12). Only
/// purchases an SMS timed count; `HourPattern` (LedgerKit) places, shades and words the cells.
struct HourPatternView: View {
    let range: AnalysisRange
    let profileCode: String
    @Environment(AnalysisScreens.self) private var screens
    @State private var loader: AnalysisLoader<AnalysisRange, HourPattern>?

    var body: some View {
        Page {
            Text(range.label()).font(Typography.caption).foregroundStyle(Palette.muted).padding(.top, 8)
            if let loader {
                StateContainer(state: loader.state, retry: reload) { pattern in
                    if pattern.isEmpty {
                        AnalysisEmptyCard(systemImage: "clock", title: HourPattern.emptyTitle, message: HourPattern.emptyBody)
                    } else {
                        HourGridCard(pattern: pattern)
                    }
                }
            } else {
                LoadingCard()
            }
        }
        .ledgerNavigation(HourPattern.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: AnalysisTaskKey(profileCode: profileCode, request: range)) {
            let l = loader ?? screens.hours()
            loader = l
            await l.loadIfNeeded(profileCode: profileCode, request: range)
        }
        .refreshable { await loader?.load(profileCode: profileCode, request: range) }
    }

    private func reload() {
        guard let loader else { return }
        Task { await loader.load(profileCode: profileCode, request: range) }
    }
}

private struct Slot: Hashable {
    let dow: Int
    let hour: Int
}

private struct HourGridCard: View {
    let pattern: HourPattern
    @State private var selected: Slot?

    private let labelWidth: CGFloat = 30
    private let gap: CGFloat = 2

    var body: some View {
        Card {
            Group {
                if let selected, let readout = pattern.readout(dow: selected.dow, hour: selected.hour) {
                    Text(readout).font(Typography.rowMeta).foregroundStyle(Palette.ink)
                } else {
                    Text(HourPattern.hint).font(Typography.rowMeta).foregroundStyle(Palette.muted)
                }
            }
            .frame(minHeight: 40, alignment: .topLeading)
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    Color.clear.frame(width: labelWidth, height: 12)
                    ForEach(0..<24, id: \.self) { hour in
                        Text(HourPattern.hourLabels[hour])
                            .font(.system(size: 9)).monospacedDigit().foregroundStyle(Palette.muted)
                            .lineLimit(1).fixedSize()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .accessibilityHidden(true)
                ForEach(1...7, id: \.self) { dow in row(dow) }
            }
            HeatLegend()
            Text(HourPattern.footnote).font(Typography.caption).foregroundStyle(Palette.muted)
        }
    }

    private func row(_ dow: Int) -> some View {
        HStack(spacing: gap) {
            Text(AnalysisFormat.weekdays[dow - 1]).font(Typography.caption).foregroundStyle(Palette.muted)
                .frame(width: labelWidth, alignment: .leading)
                .accessibilityHidden(true)
            ForEach(0..<24, id: \.self) { hour in
                let slot = Slot(dow: dow, hour: hour)
                Button {
                    selected = pattern.cell(dow: dow, hour: hour) == nil || selected == slot ? nil : slot
                } label: {
                    HeatCell(level: pattern.cell(dow: dow, hour: hour)?.level ?? 0, cornerRadius: 2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                        .overlay {
                            if selected == slot { RoundedRectangle(cornerRadius: 2).stroke(Palette.ink, lineWidth: 1.5) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(pattern.accessibilityLabel(dow: dow, hour: hour))
                .accessibilityAddTraits(selected == slot ? .isSelected : [])
            }
        }
    }
}
