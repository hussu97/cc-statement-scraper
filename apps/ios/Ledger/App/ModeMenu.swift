import LedgerKit
import SwiftUI

/// The header's mode switch (Wealth mode): `Spending ⌄` / `Wealth ⌄` / `India ⌄` in each root
/// screen's navigation bar, a menu of the modes the ledger has (`TabRouter.modes`: India only with
/// a Kite or Coin account). Which tabs each shows is `AppMode`'s.
struct ModeMenu: View {
    @Environment(TabRouter.self) private var tabs: TabRouter?

    var body: some View {
        if let tabs {
            Menu {
                Picker("Mode", selection: Binding(get: { tabs.mode }, set: { tabs.switchMode($0) })) {
                    ForEach(tabs.modes) { mode in
                        Label {
                            Text(mode.title)
                            Text(mode.subtitle)
                        } icon: {
                            Image(systemName: mode.systemImage)
                        }
                        .tag(mode)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(tabs.mode.title).font(Typography.rowTitle.weight(.semibold)).foregroundStyle(Palette.ink)
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: Metrics.tapMin)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Mode")
            .accessibilityValue(tabs.mode.title)
            .accessibilityHint(AppMode.menuHint(tabs.modes))
        }
    }
}

extension View {
    /// A root screen's navigation bar: its title, and the mode menu in the middle.
    func rootNavigation(_ title: String) -> some View {
        ledgerNavigation(title)
            .toolbar {
                ToolbarItem(placement: .principal) { ModeMenu() }
            }
    }
}
