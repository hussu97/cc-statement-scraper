import Foundation

/// The app's halves (Wealth mode, tasks/todo.md §5), switched from the menu in each root
/// screen's title. Spending is the card tracker with budgets; Wealth is the bank accounts, their
/// ledgers, investments (gold and silver for now, §6), cash flow and net worth (goals join later). Settings
/// (cards, statements) is shared, so it is in both tab sets. India is the Zerodha Kite and Coin
/// accounts in rupees (`india_overview`), kept apart from Wealth and offered only for a ledger that
/// has one (`TabRouter.modes`).
public enum AppMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case spending, wealth, india

    public var id: String { rawValue }

    /// The menu's title and the title button: `"Spending"` / `"Wealth"` / `"India"`.
    public var title: String {
        switch self {
        case .spending: "Spending"
        case .wealth: "Wealth"
        case .india: "India"
        }
    }

    /// The menu item's second line.
    public var subtitle: String {
        switch self {
        case .spending: "Card spend and budgets"
        case .wealth: "Accounts, investments and net worth"
        case .india: "Zerodha Kite and Coin, in rupees"
        }
    }

    public var systemImage: String {
        switch self {
        case .spending: "creditcard"
        case .wealth: "building.columns"
        case .india: "indianrupeesign"
        }
    }

    /// The tab bar, in order. India's is narrowed to the accounts the ledger has
    /// (`IndiaOverview.tabs`, `TabRouter.shownTabs`).
    public var tabs: [LedgerTab] {
        switch self {
        case .spending: [.overview, .activity, .insights, .budgets, .settings]
        case .wealth: [.overview, .accounts, .investments, .cashFlow, .settings]
        case .india: [.overview, .kite, .coin]
        }
    }

    /// The menu's modes: India only for a ledger with an India account.
    public static func offered(india: Bool) -> [AppMode] {
        india ? allCases : allCases.filter { $0 != .india }
    }

    /// The menu's VoiceOver hint: `"Switches between Spending and Wealth"`.
    public static func menuHint(_ modes: [AppMode]) -> String {
        let names = modes.map(\.title)
        guard names.count > 1 else { return "Switches mode" }
        return "Switches between " + names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    /// The mode a tab belongs to when the current one doesn't show it: a link into Activity
    /// from Wealth switches to Spending.
    public static func home(of tab: LedgerTab) -> AppMode {
        switch tab {
        case .accounts, .investments, .cashFlow: .wealth
        case .kite, .coin: .india
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
