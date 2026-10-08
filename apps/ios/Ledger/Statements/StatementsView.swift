import LedgerKit
import SwiftUI
import UniformTypeIdentifiers

struct StatementsView: View {
    let model: StatementsModel
    let profileCode: String
    @State private var picking = false

    var body: some View {
        Page {
            Card {
                SectionHeader(title: "Add statements")
                Text("PDFs are parsed on the server and reconciled against your SMS. Password-protected PDFs use the passwords saved on the web.")
                    .font(Typography.rowMeta).foregroundStyle(Palette.muted)
                Button {
                    picking = true
                } label: {
                    Label(model.isUploading ? "Uploading…" : "Choose PDFs", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity, minHeight: Metrics.tapMin)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isUploading)
                if let message = model.uploadMessage {
                    Text(message).font(Typography.caption).foregroundStyle(Palette.muted)
                }
            }
            .padding(.top, 8)

            StateContainer(state: model.state, retry: reload) { content in
                CyclesCard(cycles: content.cycles)
                DocumentsCard(documents: content.documents)
            }
        }
        .ledgerNavigation("Statements")
        .task { await model.load(profileCode: profileCode) }
        .refreshable { await model.load(profileCode: profileCode) }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            Task { await model.upload(urls: urls, profileCode: profileCode) }
        }
    }

    private func reload() { Task { await model.load(profileCode: profileCode) } }
}

private struct CyclesCard: View {
    let cycles: [StatementCycle]

    var body: some View {
        Card {
            SectionHeader(title: "Statements")
            if cycles.isEmpty {
                Text("No statements yet. Upload a PDF, forward one by email, or run the scraper.")
                    .font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
            ForEach(cycles) { cycle in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cycle.title).font(Typography.rowTitle)
                            Text(cycle.periodLabel ?? "\(cycle.kindLabel) · \(LedgerDates.dayLabel(cycle.statementDate))")
                                .font(Typography.caption).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            if let balance = cycle.closingBalance {
                                Text(MoneyFormat.aed(balance)).font(Typography.amount)
                            }
                            if let due = cycle.dueText() {
                                Text(due).font(Typography.caption).foregroundStyle(Palette.muted)
                            }
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(cycle.chips) { Chip(label: $0.label, tone: $0.tone) }
                        }
                    }
                }
                if cycle.id != cycles.last?.id { Divider().overlay(Palette.border) }
            }
        }
    }
}

private struct DocumentsCard: View {
    let documents: [DocumentRecord]

    var body: some View {
        Card {
            SectionHeader(title: "Uploads")
            if documents.isEmpty {
                Text("Nothing uploaded yet.").font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
            ForEach(documents) { doc in
                HStack {
                    Image(systemName: "doc.text").foregroundStyle(Palette.subtle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(doc.originalFilename).font(Typography.rowTitle).lineLimit(1)
                        Text("\(doc.bankCode ?? "Bank unknown") · \(LedgerDates.dayLabel(CalendarDay(date: doc.createdAt)))")
                            .font(Typography.caption).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    Chip(label: doc.statusLabel, tone: doc.tone)
                }
            }
        }
    }
}
