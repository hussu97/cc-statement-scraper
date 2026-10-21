import Foundation
import Observation

/// Every tab of both modes; `AppMode.tabs` says which show, in order. Statements moved under
/// Settings when Budgets took its place (2026-10-09); `SettingsRoute.statements` is how to reach
/// it. Overview and Settings are in both modes (each mode draws its own Overview).
public enum LedgerTab: String, CaseIterable, Hashable, Sendable {
    case overview, activity, insights, budgets, accounts, investments, cashFlow, settings

    public var title: String {
        switch self {
        case .overview: "Overview"
        case .activity: "Activity"
        case .insights: "Insights"
        case .budgets: "Budgets"
        case .accounts: "Accounts"
        case .investments: "Investments"
        case .cashFlow: "Cash flow"
        case .settings: "Settings"
        }
    }

    public var systemImage: String {
        switch self {
        case .overview: "circle.grid.2x2"
        case .activity: "list.bullet.rectangle"
        case .insights: "chart.bar.xaxis"
        case .budgets: "target"
        case .accounts: "building.columns"
        case .investments: "chart.line.uptrend.xyaxis"
        case .cashFlow: "arrow.left.arrow.right"
        case .settings: "gearshape"
        }
    }
}

/// Screens pushed from Settings.
public enum SettingsRoute: Hashable, Sendable {
    /// Statement cycles, uploads (picker and share-sheet queue) and their
    /// processing logs: the former Statements tab.
    case statements
    /// One statement, pushed from Statements. The path is typed, so a cycle
    /// pushed any other way has no destination and the row does nothing.
    case statement(StatementCycle)
}

/// Which mode and tab are showing, so a screen can send the reader to another tab
/// (Insights' "See all" budgets), and where a deep link (`AppLink`) lands. A tab the current
/// mode doesn't show switches to the mode that does (`AppMode.home`).
@MainActor
@Observable
public final class TabRouter {
    public var tab: LedgerTab = .overview
    /// Spending or Wealth; kept between launches when the router has defaults.
    public private(set) var mode: AppMode
    /// Overview's Review screen is pushed (bound to its navigation destination).
    public var showingReview = false
    /// The Settings tab's navigation stack (`ledger://add-statement` pushes Statements).
    public var settingsPath: [SettingsRoute] = []
    /// Filters Activity applies when it next appears (`openActivity`, `ledger://uncategorised`).
    public private(set) var activityPreset: ActivityQuery?
    /// A transaction Activity opens when it next appears (`openTransaction`).
    public private(set) var activityTransaction: String?
    /// Statements opens its PDF picker when it next appears (`ledger://add-statement`).
    public private(set) var addStatementRequested = false
    /// Bumped by every `openActivity` / `openTransaction` (and so `ledger://uncategorised`)
    /// and every `ledger://add-statement`.
    /// Activity and Statements key their `.task` on these, never on the
    /// request itself: taking the request changes it, and SwiftUI would cancel
    /// the very task applying it (mid-fetch, or in the picker's delay).
    public private(set) var activityPresetRequest = 0
    public private(set) var addStatementRequest = 0
    /// A link that came before a ledger was on screen (a cold start, the
    /// sign-in screen, the profile picker). It opens once one is.
    public private(set) var pendingLink: AppLink?
    private let today: @Sendable () -> CalendarDay
    /// Where the mode is kept (`AppMode.defaultsKey`); nil keeps it in memory (tests).
    private let defaults: UserDefaults?

    public init(defaults: UserDefaults? = nil,
                today: @escaping @Sendable () -> CalendarDay = { LedgerDates.today() }) {
        self.defaults = defaults
        self.today = today
        mode = AppMode.restored(defaults?.string(forKey: AppMode.defaultsKey))
    }

    /// The title menu: shows the mode's tabs, staying on the tab when the new mode has it
    /// (Settings, Overview) and otherwise opening its Overview.
    public func switchMode(_ newMode: AppMode) {
        guard newMode != mode else { return }
        mode = newMode
        defaults?.set(newMode.rawValue, forKey: AppMode.defaultsKey)
        if !newMode.tabs.contains(tab) { tab = .overview }
    }

    /// Shows `tab`, in the mode that has it.
    public func show(_ tab: LedgerTab) {
        if !mode.tabs.contains(tab) { switchMode(AppMode.home(of: tab)) }
        self.tab = tab
    }

    /// Switches to Activity showing `query`'s filters (and search), replacing
    /// the ones it had: Overview's counts and strips, Insights' merchants and
    /// categories, the `ledger://uncategorised` link (PAR-4).
    public func openActivity(_ query: ActivityQuery) {
        activityPreset = query
        activityTransaction = nil
        activityPresetRequest += 1
        show(.activity)
    }

    /// Switches to Activity with one transaction's sheet open over its current
    /// filters (Overview's recent rows).
    public func openTransaction(_ txnCode: String) {
        activityPreset = nil
        activityTransaction = txnCode
        activityPresetRequest += 1
        show(.activity)
    }

    /// Switches to Settings with Statements pushed (a "payment due" insight, PAR-9).
    public func openStatements() {
        settingsPath = [.statements]
        show(.settings)
    }

    /// Opens `link` now when a ledger is on screen, else keeps it for `ledgerShown`.
    public func open(_ link: AppLink, ledgerOnScreen: Bool) {
        guard ledgerOnScreen else {
            pendingLink = link
            return
        }
        pendingLink = nil
        switch link {
        case .review:
            // Review is pushed on Spending's Overview.
            switchMode(.spending)
            show(.overview)
            showingReview = true
        case .uncategorised:
            openActivity(.uncategorised(month: today().startOfMonth))
        case .addStatement:
            settingsPath = [.statements]
            addStatementRequested = true
            addStatementRequest += 1
            show(.settings)
        case .settings:
            show(.settings)
        }
    }

    /// Activity takes the preset once (and applies it).
    public func takeActivityPreset() -> ActivityQuery? {
        defer { activityPreset = nil }
        return activityPreset
    }

    /// Activity takes the transaction to open once.
    public func takeActivityTransaction() -> String? {
        defer { activityTransaction = nil }
        return activityTransaction
    }

    /// Statements asks whether to open its picker: once, and only for someone
    /// who can upload (a viewer sees Statements with its viewer note instead).
    public func takeAddStatementRequest(canUpload: Bool) -> Bool {
        defer { addStatementRequested = false }
        return addStatementRequested && canUpload
    }

    /// A ledger's tabs are on screen: open the link that waited for one.
    public func ledgerShown() {
        if let pendingLink { open(pendingLink, ledgerOnScreen: true) }
    }

    /// A new ledger starts on Overview with nothing pushed, in the mode the reader chose. A
    /// waiting link is kept: it opens in the ledger now being shown.
    public func reset() {
        tab = .overview
        showingReview = false
        settingsPath = []
        activityPreset = nil
        activityTransaction = nil
        addStatementRequested = false
    }

    /// Signing out also forgets a waiting link.
    public func signedOut() {
        reset()
        pendingLink = nil
    }
}
