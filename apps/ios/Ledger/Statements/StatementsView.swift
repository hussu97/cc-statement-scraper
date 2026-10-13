import LedgerKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Statements (a tab until Budgets took its place): the live
/// upload log (toolbar `+`), PDFs waiting from the share sheet, statement
/// cycles (each opens its detail) and uploads (each opens its processing log).
struct StatementsView: View {
    let model: StatementsModel
    let profileCode: String
    let canUpload: Bool
    /// Asks for the picker on arrival (`ledger://add-statement`, the Control).
    var tabs: TabRouter?
    @State private var picking = false
    @State private var logFor: DocumentRecord?

    var body: some View {
        Page {
            if !canUpload {
                Text("You're a viewer on this ledger. Only its owners can add statements.")
                    .font(Typography.rowMeta).foregroundStyle(Palette.muted).padding(.top, 8)
            }
            if let message = model.uploadMessage {
                Text(message).font(Typography.caption).foregroundStyle(Palette.danger).padding(.top, 8)
            }
            if !model.uploads.isEmpty { UploadLogCard(session: model.uploads).padding(.top, 8) }
            if model.waitingLabel != nil || !model.rejected.isEmpty {
                WaitingCard(model: model, profileCode: profileCode)
            }

            StateContainer(state: model.cycles.state, retry: reload) { cycles in
                CyclesCard(cycles: cycles, model: model, profileCode: profileCode, canUpload: canUpload,
                           footer: PagingFooter(footer: model.cycles.footer,
                                                endMessage: ListEnd.message(count: cycles.count, singular: "statement",
                                                                            plural: "statements"),
                                                loadMore: { await model.cycles.loadMore() }))
            }
            StateContainer(state: model.documents.state, retry: reload) { documents in
                DocumentsCard(documents: documents, open: { logFor = $0 },
                              footer: PagingFooter(footer: model.documents.footer,
                                                   endMessage: ListEnd.message(count: documents.count,
                                                                               total: model.documents.total,
                                                                               singular: "upload", plural: "uploads"),
                                                   loadMore: { await model.documents.loadMore() }))
            }
        }
        .ledgerNavigation("Statements")
        .toolbar {
            if canUpload {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { picking = true } label: { Image(systemName: "plus") }
                        .disabled(model.isUploading)
                        .accessibilityLabel(model.isUploading ? "Uploading statements" : "Add statement PDFs")
                }
            }
        }
        .task { await model.loadIfNeeded(profileCode: profileCode) }
        .refreshable { await model.load(profileCode: profileCode) }
        // ledger://add-statement: open the picker once the push has landed. Keyed on the
        // request count: taking the request must not cancel the delay before the picker.
        .task(id: tabs?.addStatementRequest) {
            guard tabs?.takeAddStatementRequest(canUpload: canUpload) == true else { return }
            try? await Task.sleep(for: .milliseconds(400))
            picking = true
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            Task { await model.upload(urls: urls, profileCode: profileCode) }
        }
        .navigationDestination(for: StatementCycle.self) { cycle in
            StatementDetailScreen(make: { model.detailModel(for: cycle) }, profileCode: profileCode,
                                  canEdit: canUpload)
        }
        .sheet(item: $logFor) { doc in
            DocumentLogView(model: model.documentLog(for: doc), profileCode: profileCode)
        }
    }

    private func reload() { Task { await model.load(profileCode: profileCode) } }
}

/// PDFs shared from another app that haven't reached the server (BACKLOG
/// IOS-16r), and the ones it refused for good.
private struct WaitingCard: View {
    let model: StatementsModel
    let profileCode: String

    var body: some View {
        Card {
            if let waiting = model.waitingLabel {
                AdaptiveRow(alignment: .center) {
                    Label(waiting, systemImage: "tray.full").font(Typography.rowTitle).foregroundStyle(Palette.ink)
                } trailing: {
                    Button {
                        Task { await model.sendWaiting(profileCode: profileCode) }
                    } label: {
                        if model.isSendingWaiting { ProgressView() } else { Text("Send now") }
                    }
                    .buttonStyle(.bordered).tint(Palette.accent)
                    .frame(minHeight: Metrics.tapMin)
                }
            }
            ForEach(model.rejected) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Label(item.filename, systemImage: "xmark.octagon").font(Typography.rowTitle).foregroundStyle(Palette.danger)
                    Text(item.reason).font(Typography.caption).foregroundStyle(Palette.ink2)
                    Button("Remove", role: .destructive) { Task { await model.discard(item) } }
                        .font(Typography.rowMeta).frame(minHeight: Metrics.tapMin)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct CyclesCard: View {
    let cycles: [StatementCycle]
    let model: StatementsModel
    let profileCode: String
    let canUpload: Bool
    let footer: PagingFooter

    var body: some View {
        Card {
            SectionHeader(title: "Cycles", trailing: cycles.isEmpty ? nil : "Newest first")
            if cycles.isEmpty {
                Text(canUpload
                     ? "No statements yet. Tap + to upload a PDF (password-protected PDFs use the passwords saved on the web), forward one by email, or run the scraper."
                     : "No statements yet.")
                    .font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
            ForEach(cycles) { cycle in
                NavigationLink(value: cycle) {
                    CycleRow(cycle: cycle, isLatest: model.latestStatementCodes.contains(cycle.stmtCode))
                }
                .buttonStyle(.plain)
                if cycle.id != cycles.last?.id { Divider().overlay(Palette.border) }
            }
            if !cycles.isEmpty { footer }
        }
    }
}

private struct CycleRow: View {
    let cycle: StatementCycle
    let isLatest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AdaptiveRow(alignment: .center) {
                HStack(spacing: 10) {
                    BankLogo(bankCode: cycle.bankCode, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cycle.cardSuffix).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                        Text(cycle.periodLabel ?? "\(cycle.kindLabel) · \(LedgerDates.dayLabel(cycle.statementDate))")
                            .font(Typography.caption).foregroundStyle(Palette.muted)
                    }
                }
            } trailing: {
                HStack(spacing: 8) {
                    VStack(alignment: .trailing, spacing: 2) {
                        if let balance = cycle.closingBalance {
                            Text(MoneyFormat.aed(balance)).font(Typography.amount).moneyLine().foregroundStyle(Palette.ink)
                        }
                        if let due = cycle.due(isLatest: isLatest) {
                            Text(due.text).font(Typography.caption).foregroundStyle(due.tone.color)
                        }
                    }
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.subtle)
                        .accessibilityHidden(true)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(cycle.chips) { Chip(label: $0.label, tone: $0.tone) }
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the statement")
    }
}

private struct DocumentsCard: View {
    let documents: [DocumentRecord]
    let open: (DocumentRecord) -> Void
    let footer: PagingFooter

    var body: some View {
        Card {
            SectionHeader(title: "Uploads")
            if documents.isEmpty {
                Text("Nothing uploaded yet.").font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
            ForEach(documents) { doc in
                Button { open(doc) } label: { DocumentRow(doc: doc) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows the processing log")
            }
            if !documents.isEmpty { footer }
        }
    }
}

private struct DocumentRow: View {
    let doc: DocumentRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AdaptiveRow(alignment: .center) {
                HStack(spacing: 10) {
                    if let bank = doc.bankCode {
                        BankLogo(bankCode: bank, size: 24)
                    } else {
                        Image(systemName: "doc.text").foregroundStyle(Palette.subtle).frame(width: 24)
                            .accessibilityLabel("Bank unknown")
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(doc.originalFilename).font(Typography.rowTitle).foregroundStyle(Palette.ink).lineLimit(2)
                        Text(LedgerDates.dayLabel(CalendarDay(date: doc.createdAt)))
                            .font(Typography.caption).foregroundStyle(Palette.muted)
                    }
                }
            } trailing: {
                Chip(label: doc.statusLabel, tone: doc.tone)
            }
            if let failure = doc.failureDetail {
                Text(failure).font(Typography.caption).foregroundStyle(Palette.danger).lineLimit(3)
            }
            if let advice = UploadAdvice.forDocument(doc) {
                Text(advice).font(Typography.caption).foregroundStyle(Palette.ink2)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
