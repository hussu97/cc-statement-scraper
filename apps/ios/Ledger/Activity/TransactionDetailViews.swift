import LedgerKit
import SwiftUI

/// The read-only transaction sheet (PAR-2): what a viewer opens, and what a
/// related transaction pushes. Owners get `CategorySheet`, which shows the same
/// sections under its edit controls. `TransactionDetailModel` decides.
struct TransactionDetailSheet: View {
    let model: TransactionDetailModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TransactionDetailList(model: model)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
    }
}

/// Header, details, category and notes as text, reversal and evidence.
struct TransactionDetailList: View {
    let model: TransactionDetailModel

    var body: some View {
        let txn = model.transaction
        List {
            Section { TransactionDetailHeader(txn: txn) }
            TransactionDetailSections(model: model) {
                DetailRow(label: "Category") {
                    Text([txn.categoryName ?? "Uncategorised", TransactionEditor.sourceLabel(txn.categorySource)]
                        .compactMap { $0 }.joined(separator: " · "))
                }
            }
            if let notes = txn.notes {
                Section("Notes") { Text(notes).textSelection(.enabled) }
            }
            TransactionEvidenceSection(model: model)
        }
        .navigationTitle("Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .onDisappear { model.closeAllSMS() }
    }
}

/// Merchant, amount, original amount and the badges.
struct TransactionDetailHeader: View {
    let txn: LedgerTransaction

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(txn.title).font(Typography.rowTitle).foregroundStyle(Palette.ink)
            if txn.merchantName != nil, !txn.description.isEmpty {
                Text(txn.description).font(Typography.caption).foregroundStyle(Palette.muted)
            }
            Text(txn.amountLabel).font(Typography.amountLarge).moneyLine()
                .foregroundStyle(txn.isCredit ? Palette.positive : Palette.ink)
            if let original = txn.originalAmountLabel, txn.amountAed != nil {
                Text(original).font(Typography.rowMeta).moneyLine().foregroundStyle(Palette.muted)
            }
            FlowChips(badges: txn.detailBadges).padding(.top, 2)
        }
        .padding(.vertical, 4)
    }
}

/// The details list and the reversal link; `category` is the owner's or viewer's category row.
struct TransactionDetailSections<Category: View>: View {
    let model: TransactionDetailModel
    @ViewBuilder var category: Category

    var body: some View {
        let txn = model.transaction
        Section("Details") {
            DetailRow(label: "Date") { Text(txn.whenLabel) }
            if let posted = txn.postedLabel { DetailRow(label: "Posted") { Text(posted) } }
            DetailRow(label: "Card") {
                VStack(alignment: .leading, spacing: 2) {
                    BankCardLabel(bankCode: txn.bankCode, label: txn.cardSuffix, size: 18, font: Typography.rowMeta)
                    if let nickname = txn.accountNickname { Text(nickname).foregroundStyle(Palette.muted) }
                    if let peer = txn.transferPeer { TransferPeerLabel(peer: peer, size: 18, font: Typography.rowMeta) }
                }
            }
            category
            if model.hasMerchant {
                if let line = model.merchantLine {
                    DetailRow(label: "Merchant") { Text(line).monospacedDigit() }
                } else if model.merchantFailed {
                    DetailRow(label: "Merchant") { Text("Couldn't load your history here.").foregroundStyle(Palette.muted) }
                }
            }
            if let foreign = txn.foreignAmountLine { DetailRow(label: "Foreign amount") { Text(foreign).monospacedDigit() } }
            if let authorised = txn.authorisedLine { DetailRow(label: "Authorised") { Text(authorised).monospacedDigit() } }
        }
        if !model.related.isEmpty {
            Section(txn.relatedTitle) {
                ForEach(model.related) { related in
                    NavigationLink {
                        TransactionDetailList(model: model.detail(for: related))
                    } label: {
                        HStack {
                            Text("\(related.title) · \(LedgerDates.dayLabel(related.txnDate))").lineLimit(1)
                            Spacer(minLength: 8)
                            Text(related.amountLabel).moneyLine()
                                .foregroundStyle(related.isCredit ? Palette.positive : Palette.ink)
                        }
                        .font(Typography.rowMeta)
                    }
                }
            }
        }
    }
}

/// The evidence timeline: statement lines and SMS, the SMS text on request.
struct TransactionEvidenceSection: View {
    let model: TransactionDetailModel

    var body: some View {
        Section("Evidence") {
            switch model.evidence {
            case .idle, .loading(nil):
                ProgressView().frame(maxWidth: .infinity)
            case .failed(let message, _):
                Text(message).foregroundStyle(Palette.muted)
            default:
                if let empty = model.noEvidenceMessage {
                    Text(empty).foregroundStyle(Palette.muted)
                }
                ForEach(model.evidence.value ?? []) { item in EvidenceRow(item: item, model: model) }
            }
        }
    }
}

private struct EvidenceRow: View {
    let item: EvidenceItem
    let model: TransactionDetailModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: item.isSMS ? "message" : "doc.text").foregroundStyle(Palette.muted)
                Text(item.title).fontWeight(.semibold)
                Text(item.roleLabel).foregroundStyle(Palette.muted)
                if item.isLocked { Image(systemName: "lock").font(.caption).accessibilityLabel("Locked by review") }
                if !item.isActive { Chip(label: "detached") }
            }
            .font(Typography.rowMeta)
            Text(item.whenLabel).font(Typography.caption).foregroundStyle(Palette.muted)
            if let line = item.statementLines {
                Text(line.descriptionRaw).font(.caption.monospaced()).foregroundStyle(Palette.ink)
                if let summary = item.lineSummary {
                    Text(summary).font(Typography.caption).monospacedDigit().foregroundStyle(Palette.muted)
                }
            }
            if let sms = item.smsMessages { smsBlock(sms) }
        }
        .opacity(item.isActive ? 1 : 0.55)
        .padding(.vertical, 2)
    }

    @ViewBuilder private func smsBlock(_ sms: EvidenceItem.SMS) -> some View {
        if let header = item.smsHeader { Text(header).font(Typography.caption).foregroundStyle(Palette.muted) }
        if let detail = item.smsDetail {
            Text(detail).font(Typography.caption).monospacedDigit().foregroundStyle(Palette.muted)
        }
        Button {
            Task { await model.toggleSMS(sms.smsCode) }
        } label: {
            Label(model.isOpen(sms.smsCode) ? "Hide message" : "Show message",
                  systemImage: model.isOpen(sms.smsCode) ? "chevron.up" : "chevron.down")
                .font(Typography.caption)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Palette.accent)
        if let body = model.openSMS[sms.smsCode] {
            Group {
                switch body {
                case .loaded(let text): Text(text).textSelection(.enabled)
                case .failed(let message, _): Text(message)
                default: Text("Loading…")
                }
            }
            .font(Typography.caption)
            .foregroundStyle(Palette.ink)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radiusMd))
        }
    }
}

/// A label and its value, side by side.
struct DetailRow<Value: View>: View {
    let label: String
    @ViewBuilder var value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(Palette.muted).frame(width: 100, alignment: .leading)
            value.foregroundStyle(Palette.ink).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Typography.rowMeta)
        .accessibilityElement(children: .combine)
    }
}

/// Badges that wrap onto as many lines as they need.
private struct FlowChips: View {
    let badges: [DetailBadge]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chips }
            VStack(alignment: .leading, spacing: 6) { chips }
        }
    }

    private var chips: some View {
        ForEach(badges, id: \.self) { Chip(label: $0.label, tone: $0.tone) }
    }
}
