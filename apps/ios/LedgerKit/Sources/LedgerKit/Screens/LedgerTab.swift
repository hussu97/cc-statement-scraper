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
/// (Insights' "See all" budgets).
@MainActor
@Observable
public final class TabRouter {
    public var tab: LedgerTab = .overview

    public init() {}

    public func show(_ tab: LedgerTab) { self.tab = tab }

    /// A new ledger (or sign-out) starts on Overview.
    public func reset() { tab = .overview }
}
