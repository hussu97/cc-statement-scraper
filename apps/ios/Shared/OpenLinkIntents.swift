import AppIntents
import LedgerKit

// Compiled into the app and the widget extension (project.yml): a Control's
// action must be an intent both know. `openAppWhenRun` makes the system bring
// the app forward and perform them there; each hands its `AppLink` to
// `AppLinkInbox`, which the app's `TabRouter` takes (BACKLOG N-4). (Returning
// `OpenURLIntent(ledger://…)` from the widget extension opened nothing.) They
// also show in Shortcuts, so the Action button can run them. No text names an
// Apple product (ITMS-90626).

/// Activity, filtered to this month's uncategorised transactions.
struct OpenUncategorisedIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Uncategorised"
    static let description = IntentDescription(
        "Opens Bank Ledger's Activity on this month's uncategorised transactions.")
    static let isDiscoverable = true
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppLinkInbox.deliver(.uncategorised)
        return .result()
    }
}

/// Settings → Statements with the PDF picker open.
struct AddStatementIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Statement"
    static let description = IntentDescription(
        "Opens Bank Ledger's Statements with the file picker, to upload a statement PDF.")
    static let isDiscoverable = true
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppLinkInbox.deliver(.addStatement)
        return .result()
    }
}
