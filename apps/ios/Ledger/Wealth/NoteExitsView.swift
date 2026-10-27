import LedgerKit
import SwiftUI

/// A live note's two ways out side by side: sold today at the broker's bid, and called at its
/// next autocall date. The words are LedgerKit's (`NoteExit`).
struct NoteExitsView: View {
    let exits: [NoteExit]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(exits) { exit in
                VStack(alignment: .leading, spacing: 2) {
                    Text(exit.title).font(Typography.caption).foregroundStyle(Palette.muted).lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(exit.totalText).font(Typography.rowMeta).foregroundStyle(Palette.ink).moneyLine()
                    Text(exit.profitText).font(Typography.caption).foregroundStyle(exit.tone.color).moneyLine()
                    if let detail = exit.detail {
                        Text(detail).font(Typography.caption).foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(Palette.surface2, in: RoundedRectangle(cornerRadius: Metrics.radiusMd))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(exit.accessibilityLabel)
            }
        }
    }
}
