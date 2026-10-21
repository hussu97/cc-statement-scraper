import LedgerKit
import SwiftUI

/// The holding form's sections for plans, broker accounts, shares and funds, and fixed deposits:
/// institution and currency, the kind's own fields (units and symbol; principal, rate, start and
/// maturity), a start date, and the payment rule that links matching payments. Layout only:
/// `HoldingDraft` validates and words them.
struct HoldingKindFields: View {
    @Binding var draft: HoldingDraft

    var body: some View {
        Section {
            TextField(draft.institutionPlaceholder, text: $draft.institution)
                .textInputAutocapitalization(.words)
                .accessibilityLabel("Institution")
            Picker("Currency", selection: $draft.currency) {
                ForEach(draft.currencyChoices, id: \.self) { Text($0).tag($0) }
            }
        } header: {
            Text("Held with")
        } footer: {
            Text(HoldingDraft.currencyNote)
        }
        switch draft.kind {
        case .security: securitySection
        case .deposit: depositSection
        default: dateSection
        }
        Section {
            TextField("e.g. RL360", text: $draft.linkPattern)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .accessibilityLabel(draft.linkExact ? "Payment rule: description is exactly" : "Payment rule: description contains")
            Toggle(isOn: $draft.linkExact) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(HoldingDraft.linkExactTitle)
                    Text(HoldingDraft.linkExactHint).font(Typography.caption).foregroundStyle(Palette.muted)
                }
            }
            .tint(Palette.accent)
        } header: {
            Text("Payment rule (optional)")
        } footer: {
            Text([draft.linkRuleNote, draft.isEditing ? nil : draft.afterAddNote].compactMap { $0 }
                .joined(separator: "\n\n"))
        }
    }

    private var securitySection: some View {
        Section {
            HStack {
                Text("Units").foregroundStyle(Palette.muted)
                TextField("e.g. 1000", text: $draft.units)
                    .keyboardType(.decimalPad).monospacedDigit().multilineTextAlignment(.trailing)
                    .accessibilityLabel("Units held")
            }
            HStack {
                Text("Symbol").foregroundStyle(Palette.muted)
                TextField("Optional, e.g. EXCO", text: $draft.symbol)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel("Symbol")
            }
            dateRows
        } header: {
            Text("Shares or fund")
        } footer: {
            Text("Its value is the units times the latest price you record on its page.")
        }
    }

    private var depositSection: some View {
        Section {
            HStack {
                Text(draft.currency).foregroundStyle(Palette.muted)
                TextField("Amount deposited", text: $draft.principal)
                    .keyboardType(.decimalPad).monospacedDigit()
                    .accessibilityLabel("Amount deposited, in \(draft.currency)")
            }
            HStack {
                Text("Profit rate").foregroundStyle(Palette.muted)
                TextField("e.g. 4.25", text: $draft.ratePct)
                    .keyboardType(.decimalPad).monospacedDigit().multilineTextAlignment(.trailing)
                    .accessibilityLabel("Profit rate a year, in percent")
                Text("% a year").foregroundStyle(Palette.muted)
            }
            DatePicker(draft.dateTitle, selection: day(\.acquiredOn), in: ...Date.now, displayedComponents: .date)
                .environment(\.timeZone, LedgerDates.timeZone)
            DatePicker("Matures on", selection: day(\.maturityOn), in: draft.acquiredOn.adding(days: 1).startDate...,
                       displayedComponents: .date)
                .environment(\.timeZone, LedgerDates.timeZone)
        } header: {
            Text("Deposit")
        } footer: {
            Text("Its value is the amount plus profit accrued each day to maturity, at simple interest: an estimate.")
        }
    }

    private var dateSection: some View {
        Section { dateRows } header: { Text("Started") }
    }

    @ViewBuilder private var dateRows: some View {
        Toggle(draft.dateTitle, isOn: $draft.hasAcquiredOn.animation())
        if draft.hasAcquiredOn {
            DatePicker(draft.dateTitle, selection: day(\.acquiredOn), in: ...Date.now, displayedComponents: .date)
                .environment(\.timeZone, LedgerDates.timeZone)
        }
    }

    /// A date picker edits a Dubai calendar day.
    private func day(_ path: WritableKeyPath<HoldingDraft, CalendarDay>) -> Binding<Date> {
        Binding(get: { draft[keyPath: path].startDate }, set: { draft[keyPath: path] = CalendarDay(date: $0) })
    }
}
