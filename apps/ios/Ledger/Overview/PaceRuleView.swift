import LedgerKit
import SwiftUI

/// The current month's spend drawn as a filled line, with pins where last month and the
/// 3-month average stood by today, a key under it and the server's projection (PAR-6, web
/// `PaceRule`). Positions and words come from `PaceRule` (LedgerKit).
struct PaceRuleView: View {
    let rule: PaceRule

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.surface3).frame(height: 3)
                    if let at = rule.spendAt {
                        Capsule().fill(Palette.accent).frame(width: max(width * at, 7), height: 7)
                    }
                    ForEach(rule.pins) { pin in
                        if let at = pin.at {
                            Rectangle().fill(pinColor(pin.key)).frame(width: 2, height: pinHeight(pin.key))
                                .offset(x: min(max(width * at - 1, 0), width - 2))
                        }
                    }
                    if let at = rule.spendAt {
                        Circle().fill(Palette.accent).frame(width: 15, height: 15)
                            .overlay(Circle().stroke(Palette.bg, lineWidth: 3))
                            .offset(x: min(max(width * at - 7.5, 0), width - 15))
                    }
                }
                .frame(height: 20)
            }
            .frame(height: 20)

            VStack(alignment: .leading, spacing: 4) {
                key(swatch: Capsule().fill(Palette.accent).frame(width: 12, height: 5), label: "This month",
                    amount: rule.spendLabel)
                ForEach(rule.pins) { pin in
                    key(swatch: Rectangle().fill(pinColor(pin.key)).frame(width: 2, height: pinHeight(pin.key) * 0.6),
                        label: pin.label,
                        amount: pin.amountLabel)
                }
            }
            if let projection = rule.projection {
                Text(projection).font(Typography.rowMeta).foregroundStyle(Palette.muted).monospacedDigit()
            }
        }
        .padding(.top, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Spending pace this month")
        .accessibilityValue(rule.accessibilityLabel)
    }

    private func key(swatch: some View, label: String, amount: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            swatch.frame(width: 12)
            Text(label).font(Typography.caption).foregroundStyle(Palette.muted)
            Spacer(minLength: 8)
            Text(amount).font(Typography.caption.weight(.medium)).foregroundStyle(Palette.ink).monospacedDigit()
        }
    }

    /// Last month's pin is the taller, darker one; the average's the shorter, lighter one.
    private func pinColor(_ key: PaceRule.Pin.Key) -> Color {
        key == .prev ? Palette.ink2 : Palette.muted
    }

    private func pinHeight(_ key: PaceRule.Pin.Key) -> CGFloat {
        key == .prev ? 20 : 12
    }
}
