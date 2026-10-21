import Foundation

/// The app's two halves (Wealth mode, tasks/todo.md §5), switched from the menu in each root
/// screen's title. Spending is the card tracker with budgets; Wealth is the bank accounts, their
/// ledgers, investments (gold and silver for now, §6), cash flow and net worth (goals join later). Settings
/// (cards, statements) is shared, so it is in both tab sets.
public enum AppMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case spending, wealth

    public var id: String { rawValue }

    /// The menu's title and the title button: `"Spending"` / `"Wealth"`.
    public var title: String {
        switch self {
        case .spending: "Spending"
        case .wealth: "Wealth"
        }
    }

    /// The menu item's second line.
    public var subtitle: String {
        switch self {
        case .spending: "Card spend and budgets"
        case .wealth: "Accounts, investments and net worth"
        }
    }

    public var systemImage: String {
        switch self {
        case .spending: "creditcard"
        case .wealth: "building.columns"
        }
    }

    /// The tab bar, in order.
    public var tabs: [LedgerTab] {
        switch self {
        case .spending: [.overview, .activity, .insights, .budgets, .settings]
        case .wealth: [.overview, .accounts, .investments, .cashFlow, .settings]
        }
    }

    /// The mode a tab belongs to when the current one doesn't show it: a link into Activity
    /// from Wealth switches to Spending.
    public static func home(of tab: LedgerTab) -> AppMode {
        switch tab {
        case .accounts, .investments, .cashFlow: .wealth
        default: .spending
        }
    }

    /// The saved mode, or Spending (the app as it was) for none or a value this build doesn't know.
    public static func restored(_ raw: String?) -> AppMode {
        raw.flatMap(AppMode.init(rawValue:)) ?? .spending
    }

    /// Where the mode is kept between launches (this device only).
    public static let defaultsKey = "ledger.appMode"
}
