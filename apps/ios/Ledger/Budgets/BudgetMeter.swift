import LedgerKit
import SwiftUI

/// A budget's meter: the server's share used, and in the current month a tick where the
/// budget's even share by today falls (`expected_share`, PAR-7; web `Meter` with a marker).
struct BudgetMeter: View {
    let row: BudgetStatus
    let phase: BudgetMonthPhase

    var body: some View {
        let tone = row.tone(isCurrentMonth: phase == .current)
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.surface3).frame(height: 6)
                Capsule().fill(tone.color).frame(width: width * row.progressFraction, height: 6)
                if let tick = row.paceTick(phase) {
                    Capsule().fill(Palette.ink).frame(width: 2, height: 14)
                        .offset(x: min(max(width * tick - 1, 0), width - 2))
                }
            }
            .frame(height: 14)
        }
        .frame(height: 14)
        .accessibilityElement()
        .accessibilityLabel(row.meterAccessibilityLabel(phase))
    }
}
