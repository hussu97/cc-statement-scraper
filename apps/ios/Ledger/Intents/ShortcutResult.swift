import AppIntents
import LedgerKit

/// What "Log Bank SMS" and "Log Card Payment" return: the outcome code, the
/// line Shortcuts shows and, when only the app can finish the job (a review),
/// the deep link to open after it (`ledger://review`, BACKLOG IOS-07r). Which
/// outcomes link where is decided in LedgerKit (`SMSIntakeOutcome.link`).
enum ShortcutResult {
    /// One concrete type for both shapes, so `perform` can return either.
    typealias Value = IntentResultContainer<String, Never, Never, IntentDialog>

    static func make(_ value: String, dialog: String, link: AppLink?) -> Value {
        let dialog = IntentDialog(stringLiteral: dialog)
        // Opening an intent from a result with a value and a dialog needs 18.2;
        // earlier systems show the dialog, which names the screen.
        if let link, #available(iOS 18.2, *) {
            return .result(value: value, opensIntent: OpenURLIntent(link.url), dialog: dialog)
        }
        return .result(value: value, dialog: dialog)
    }
}
