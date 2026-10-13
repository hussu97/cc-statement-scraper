import LedgerKit
import SwiftUI
import WidgetKit

/// Bank Ledger's Home and Lock Screen widgets (BACKLOG N-2). They draw the
/// snapshot the app writes to the App Group after Overview loads: no network,
/// no session. Every word they show is decided in LedgerKit (`WidgetContent`).
@main
struct LedgerWidgetBundle: WidgetBundle {
    init() {
        Telemetry.start(target: .widgets, config: WidgetStore.config, isDebugBuild: WidgetBuild.isDebug)
    }

    var body: some Widget {
        SpendWidget()
        DueWidget()
        UtilisationWidget()
    }
}

/// This target's own build flavour (LedgerKit is compiled separately).
enum WidgetBuild {
    #if DEBUG
    static let isDebug = true
    #else
    static let isDebug = false
    #endif
}

/// The App Group, found through the same `Ledger*` Info.plist keys as the app.
enum WidgetStore {
    static let config: LedgerConfig? = try? LedgerConfig.load()
    static let store: WidgetSnapshotStore? = config.map {
        WidgetSnapshotStore(container: $0.sharedContainerURL, defaults: $0.sharedDefaults)
    }
}

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    /// Settings → Require Face ID, mirrored by the app.
    let requireAuth: Bool
}

/// One provider for every widget: the snapshot on disk, refreshed at the next
/// Dubai midnight (due-in-days and the month name) or when the app reloads.
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: .sample, requireAuth: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = current()
        completion(Timeline(entries: [entry], policy: .after(WidgetTimeline.nextRefresh(after: entry.date))))
    }

    private func current() -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: WidgetStore.store?.read(),
                      requireAuth: WidgetStore.store?.hidesLockScreenAmounts ?? false)
    }
}

extension WidgetSnapshot {
    /// The widget gallery's example (made-up figures, never a person's).
    static let sample = WidgetSnapshot(
        generatedAt: .now, profileCode: "prf_sample", ledgerName: "Home", month: LedgerDates.today().startOfMonth,
        spend: 3240, spendPrevMonthToDate: 3900, changeVsPrevMonthToDate: Decimal(string: "-0.17"),
        uncategorizedCount: 2,
        cards: [
            Card(accountCode: "acc_sample_1", title: "Cashback card", dueDate: LedgerDates.today().adding(days: 6),
                 closingBalance: 4210, minDue: 210, utilisation: Decimal(string: "0.42")),
            Card(accountCode: "acc_sample_2", title: "Travel card", dueDate: LedgerDates.today().adding(days: 15),
                 closingBalance: 980, minDue: 100, utilisation: Decimal(string: "0.12")),
        ])
}

extension WidgetFamily {
    /// Accessory families are the Lock Screen's.
    var placement: WidgetPlacement {
        switch self {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline: .lockScreen
        default: .homeScreen
        }
    }
}

/// The widgets' shared frame: the brand background on the Home Screen.
struct WidgetCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(for: .widget) { Palette.surface }
    }
}

/// A short sentence instead of figures ("Open Bank Ledger to …").
struct WidgetMessage: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Palette.accent)
            Text(text).font(.footnote).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
