import Foundation
import Observation

/// The tab bar, in order. Statements moved under Settings when Budgets took
/// its place (2026-10-09); `SettingsRoute.statements` is how to reach it.
public enum LedgerTab: String, CaseIterable, Hashable, Sendable {
    case overview, activity, insights, budgets, settings

    public var title: String {
        switch self {
        case .overview: "Overview"
        case .activity: "Activity"
        case .insights: "Insights"
        case .budgets: "Budgets"
        case .settings: "Settings"
        }
    }

    public var systemImage: String {
        switch self {
        case .overview: "circle.grid.2x2"
        case .activity: "list.bullet.rectangle"
        case .insights: "chart.bar.xaxis"
        case .budgets: "target"
        case .settings: "gearshape"
        }
    }
}

/// Screens pushed from Settings.
public enum SettingsRoute: Hashable, Sendable {
    /// Statement cycles, uploads (picker and share-sheet queue) and their
    /// processing logs: the former Statements tab.
    case statements
}

/// Which tab is showing, so a screen can send the reader to another tab
/// (Insights' "See all" budgets), and where a deep link (`AppLink`) lands.
@MainActor
@Observable
public final class TabRouter {
    public var tab: LedgerTab = .overview
    /// Overview's Review screen is pushed (bound to its navigation destination).
    public var showingReview = false
    /// A link that came before a ledger was on screen (a cold start, the
    /// sign-in screen, the profile picker). It opens once one is.
    public private(set) var pendingLink: AppLink?

    public init() {}

    public func show(_ tab: LedgerTab) { self.tab = tab }

    /// Opens `link` now when a ledger is on screen, else keeps it for `ledgerShown`.
    public func open(_ link: AppLink, ledgerOnScreen: Bool) {
        guard ledgerOnScreen else {
            pendingLink = link
            return
        }
        pendingLink = nil
        switch link {
        case .review:
            tab = .overview
            showingReview = true
        }
    }

    /// A ledger's tabs are on screen: open the link that waited for one.
    public func ledgerShown() {
        if let pendingLink { open(pendingLink, ledgerOnScreen: true) }
    }

    /// A new ledger starts on Overview with nothing pushed. A waiting link is
    /// kept: it opens in the ledger now being shown.
    public func reset() {
        tab = .overview
        showingReview = false
    }

    /// Signing out also forgets a waiting link.
    public func signedOut() {
        reset()
        pendingLink = nil
    }
}
