import LedgerKit
import SwiftUI
import WidgetKit

/// Control Center, Lock Screen and Action button controls (BACKLOG N-4). Each
/// is a button whose intent opens a `ledger://` link (`Shared/OpenLinkIntents.swift`).
struct OpenUncategorisedControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: LedgerWidgetKind.openUncategorised) {
            ControlWidgetButton(action: OpenUncategorisedIntent()) {
                Label("Uncategorised", systemImage: "tag")
            }
        }
        .displayName("Open Uncategorised")
        .description("Shows this month's uncategorised transactions in Bank Ledger.")
    }
}

struct AddStatementControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: LedgerWidgetKind.addStatement) {
            ControlWidgetButton(action: AddStatementIntent()) {
                Label("Add statement", systemImage: "doc.badge.plus")
            }
        }
        .displayName("Add Statement")
        .description("Opens Statements in Bank Ledger to upload a statement PDF.")
    }
}
