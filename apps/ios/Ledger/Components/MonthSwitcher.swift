import LedgerKit
import SwiftUI

/// `‹  October 2026 ▾  ›`: previous / next month, tap the title for a month
/// picker. Bounds and wording come from `MonthSelection`; VoiceOver can also
/// swipe up and down on the title to change month.
struct MonthSwitcher: View {
    let month: MonthSelection
    @State private var picking = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: month.goBack) {
                Image(systemName: "chevron.left")
                    .foregroundStyle(month.canGoBack ? Palette.accent : Palette.subtle)
                    .frame(width: Metrics.tapMin, height: Metrics.tapMin)
                    .contentShape(Rectangle())
            }
            .disabled(!month.canGoBack)
            .accessibilityLabel(month.previousLabel)

            Button { picking = true } label: {
                HStack(spacing: 6) {
                    Text(month.title).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
                }
                .frame(maxWidth: .infinity, minHeight: Metrics.tapMin)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(month.accessibilityLabel)
            .accessibilityValue(month.accessibilityValue)
            .accessibilityHint("Opens the month picker")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: month.goForward()
                case .decrement: month.goBack()
                @unknown default: break
                }
            }

            Button(action: month.goForward) {
                Image(systemName: "chevron.right")
                    .foregroundStyle(month.canGoForward ? Palette.accent : Palette.subtle)
                    .frame(width: Metrics.tapMin, height: Metrics.tapMin)
                    .contentShape(Rectangle())
            }
            .disabled(!month.canGoForward)
            .accessibilityLabel(month.nextLabel)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.accent)
        .background(Palette.surface, in: Capsule())
        .overlay(Capsule().stroke(Palette.border, lineWidth: 0.5))
        // Swipe the switcher like a page: left for the next month, right for the previous.
        // High priority so a swipe is not also a tap on the title (the picker);
        // a tap never reaches 24 pt, so the buttons still get it.
        .highPriorityGesture(DragGesture(minimumDistance: 24).onEnded { drag in
            guard abs(drag.translation.width) > abs(drag.translation.height) else { return }
            if drag.translation.width < -40 { month.goForward() } else if drag.translation.width > 40 { month.goBack() }
        })
        .sensoryFeedback(.selection, trigger: month.month)
        .sheet(isPresented: $picking) { MonthPickerSheet(month: month) }
    }
}

/// Every month from the ledger's first transaction to this one, by year.
private struct MonthPickerSheet: View {
    let month: MonthSelection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(month.range.years) { year in
                    Section(year.title) {
                        ForEach(year.months, id: \.self) { option in
                            Button {
                                month.select(option)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(LedgerDates.monthName(option)).foregroundStyle(Palette.ink)
                                    Spacer()
                                    if option == month.month {
                                        Image(systemName: "checkmark").foregroundStyle(Palette.accent)
                                    }
                                }
                                .frame(minHeight: Metrics.tapMin)
                                .contentShape(Rectangle())
                            }
                            .accessibilityLabel(LedgerDates.monthTitle(option))
                            .accessibilityAddTraits(option == month.month ? .isSelected : [])
                        }
                    }
                }
            }
            .navigationTitle("Month")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("This month") {
                        month.select(month.range.latest)
                        dismiss()
                    }
                    .disabled(month.isCurrent)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
