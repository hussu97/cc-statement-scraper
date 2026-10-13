import AppIntents
import LedgerKit

/// "How much have I spent this month?" and "What's due?" (BACKLOG N-3): answers
/// for the ledger on screen in the app, from the server or, offline, from the
/// widgets' snapshot. Every word is `LedgerQuestions`' (LedgerKit).
///
/// Both read money aloud, so the device must be unlocked first
/// (`.requiresAuthentication`): a locked device asks for Face ID or the
/// passcode before answering. No text names an Apple product (ITMS-90626).
struct MonthSpendIntent: AppIntent {
    static let title: LocalizedStringResource = "Month Spend"
    static let description = IntentDescription(
        "Says how much you've spent on your cards this month in Bank Ledger, and how it compares with last month.")
    static let openAppWhenRun = false
    static let isDiscoverable = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let services = AppServices.shared else {
            return .result(value: "", dialog: "Bank Ledger isn't configured.")
        }
        Telemetry.start(target: .intent, config: services.config, isDebugBuild: BuildFlavor.isDebug)
        let answer = await services.questions().monthSpend()
        Telemetry.breadcrumb("question", outcome: answer.value == nil ? "no_answer" : "answered",
                             data: ["intent": "month_spend"])
        return .result(value: answer.value ?? "", dialog: IntentDialog(stringLiteral: answer.dialog))
    }
}

struct WhatsDueIntent: AppIntent {
    static let title: LocalizedStringResource = "What's Due"
    static let description = IntentDescription(
        "Lists the card statements still to pay in Bank Ledger, soonest first, with balance and minimum.")
    static let openAppWhenRun = false
    static let isDiscoverable = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        guard let services = AppServices.shared else {
            return .result(value: 0, dialog: "Bank Ledger isn't configured.")
        }
        Telemetry.start(target: .intent, config: services.config, isDebugBuild: BuildFlavor.isDebug)
        let answer = await services.questions().whatsDue()
        Telemetry.breadcrumb("question", outcome: "answered", data: ["intent": "whats_due"])
        return .result(value: answer.count, dialog: IntentDialog(stringLiteral: answer.dialog))
    }
}
