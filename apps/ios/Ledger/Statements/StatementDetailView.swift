import LedgerKit
import SwiftUI

/// Owns the detail model for as long as the screen is pushed (a destination
/// re-rendered by its parent keeps its loaded statement).
struct StatementDetailScreen: View {
    let profileCode: String
    let canEdit: Bool
    @State private var model: StatementDetailModel

    init(make: () -> StatementDetailModel, profileCode: String, canEdit: Bool) {
        self.profileCode = profileCode
        self.canEdit = canEdit
        _model = State(initialValue: make())
    }

    var body: some View { StatementDetailView(model: model, profileCode: profileCode, canEdit: canEdit) }
}

/// One statement: header, the figures it printed, reconciliation explained,
/// then its debit and credit lines. For an owner, tapping a matched line opens
/// the category sheet; viewers and view-only ledgers just read. Wording and figures are `StatementDetailModel`'s.
struct StatementDetailView: View {
    @Bindable var model: StatementDetailModel
    let profileCode: String
    let canEdit: Bool

    var body: some View {
        Page {
            StateContainer(state: model.state, retry: reload) { content in
                let header = content.detail.statement
                HeaderBlock(header: header, isLatest: model.isLatest)
                TilesGrid(tiles: header.tiles)
                ReconCard(header: header)
                LinesCard(title: "Debits", side: content.detail.debits, isCredit: false,
                          empty: "No debits on this statement.", content: content, model: model, profileCode: profileCode,
                          canEdit: canEdit)
                LinesCard(title: "Credits", side: content.detail.credits, isCredit: true,
                          empty: "No payments or refunds on this statement.", content: content, model: model,
                          profileCode: profileCode, canEdit: canEdit)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Palette.bg, for: .navigationBar)
        .task { if model.state.value == nil { await model.load(profileCode: profileCode) } }
        .refreshable { await model.load(profileCode: profileCode) }
        .sheet(item: $model.selected) { txn in
            CategorySheet(transaction: txn, categories: model.state.value?.assignable ?? [],
                          profileCode: profileCode, target: model)
        }
        .alert("Couldn't open", isPresented: Binding(get: { model.errorMessage != nil },
                                                    set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var title: String { model.state.value?.detail.statement.kindLabel ?? "Statement" }

    private func reload() { Task { await model.load(profileCode: profileCode) } }
}

private struct HeaderBlock: View {
    let header: StatementDetail.Header
    let isLatest: Bool
    @Environment(BankCatalog.self) private var banks: BankCatalog?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                if let bank = header.bankCode { BankLogo(bankCode: bank, size: 40) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(header.bankCode.map { banks?.name(for: $0) ?? $0 } ?? "Unknown bank")
                        .font(Typography.sectionTitle).foregroundStyle(Palette.ink)
                    Text([header.kindLabel, header.cardsLabel].compactMap { $0 }.joined(separator: " · "))
                        .font(Typography.rowMeta).foregroundStyle(Palette.muted)
                }
            }
            .accessibilityElement(children: .combine)
            if let period = header.periodLabel {
                Label(period, systemImage: "calendar").font(Typography.rowMeta).foregroundStyle(Palette.ink2)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { dates }
                VStack(alignment: .leading, spacing: 4) { dates }
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder private var dates: some View {
        Text("Statement \(LedgerDates.fullDayLabel(header.statementDate))")
            .font(Typography.caption).foregroundStyle(Palette.muted)
        if let due = header.dueDate {
            let status = header.due(isLatest: isLatest)
            Text("Due \(LedgerDates.fullDayLabel(due))\(status.map { " · \($0.text)" } ?? "")")
                .font(Typography.caption).foregroundStyle(status?.tone.color ?? Palette.muted)
        }
    }
}

private struct TilesGrid: View {
    let tiles: [SummaryTile]
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top),
                            count: typeSize.isAccessibilitySize ? 1 : 2)
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(tiles) { tile in
                VStack(alignment: .leading, spacing: 4) {
                    Text(tile.title).font(Typography.caption).foregroundStyle(Palette.muted)
                    Text(tile.value).font(Typography.amount).moneyLine()
                        .foregroundStyle(tile.tone == .positive ? Palette.positive : Palette.ink)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radiusMd))
                .overlay(RoundedRectangle(cornerRadius: Metrics.radiusMd).stroke(Palette.border, lineWidth: 0.5))
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct ReconCard: View {
    let header: StatementDetail.Header

    var body: some View {
        let status = ReconPresentation.status(header.reconStatus)
        let findings = ReconPresentation.findings(status: header.reconStatus, checks: header.reconChecks, header: header)
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text("Reconciliation").font(Typography.sectionTitle).foregroundStyle(Palette.ink)
                Spacer()
                Chip(label: status.label, tone: status.tone)
            }
            .accessibilityElement(children: .combine)
            ForEach(findings) { finding in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: icon(finding))
                        .foregroundStyle(finding.tone.color)
                        .accessibilityHidden(true)
                    Text(finding.text).font(Typography.rowMeta).foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityPrefix(finding) + finding.text)
            }
        }
    }

    private func icon(_ finding: ReconFinding) -> String {
        switch finding.passed {
        case true?: "checkmark.circle.fill"
        case false?: "xmark.circle.fill"
        case nil: finding.tone == .warn ? "exclamationmark.circle" : "info.circle"
        }
    }

    private func accessibilityPrefix(_ finding: ReconFinding) -> String {
        switch finding.passed {
        case true?: "Passed: "
        case false?: "Failed: "
        case nil: ""
        }
    }
}

private struct LinesCard: View {
    let title: String
    let side: StatementDetail.Side
    let isCredit: Bool
    let empty: String
    let content: StatementDetailModel.Content
    let model: StatementDetailModel
    let profileCode: String
    let canEdit: Bool

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Typography.sectionTitle).foregroundStyle(Palette.ink)
                Spacer()
                Text(side.summary).font(Typography.rowMeta).monospacedDigit().foregroundStyle(Palette.muted)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if side.lines.isEmpty {
                Text(empty).font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
            ForEach(side.lines) { line in
                if line.id != side.lines.first?.id { Divider().overlay(Palette.border) }
                let category = line.categoryCode.flatMap { content.categories[$0] }
                let label = line.accessibilityLabel(isCredit: isCredit, categoryName: category?.name)
                if canEdit {
                    Button {
                        Task { await model.open(line, profileCode: profileCode) }
                    } label: {
                        StatementLineRow(line: line, isCredit: isCredit, category: category,
                                         opening: model.opening == line.lineCode)
                    }
                    .buttonStyle(.plain)
                    .disabled(!line.canOpen)
                    .accessibilityLabel(label)
                    .accessibilityHint(line.canOpen ? "Opens the transaction" : "")
                } else {
                    StatementLineRow(line: line, isCredit: isCredit, category: category, opening: false)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(label)
                }
            }
        }
    }
}

private struct StatementLineRow: View {
    let line: StatementDetail.Line
    let isCredit: Bool
    let category: FilterMeta.CategoryOption?
    let opening: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CategoryDot(token: line.txnCode == nil ? nil : category?.colorToken, size: 10).padding(.top, 6)
            AdaptiveRow {
                VStack(alignment: .leading, spacing: 3) {
                    Text(line.title).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                        .lineLimit(typeSize.prefersStackedRows ? 4 : 2)
                    if let printed = line.printedDetail {
                        Text(printed).font(Typography.caption).foregroundStyle(Palette.muted).lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        Text(line.dateLabel)
                        Text("·")
                        Text(line.categoryLabel(category?.name))
                        if let kind = line.kindLabel { Chip(label: kind, tone: .info) }
                    }
                    .font(Typography.caption).foregroundStyle(Palette.muted)
                }
            } trailing: {
                VStack(alignment: typeSize.prefersStackedRows ? .leading : .trailing, spacing: 2) {
                    if opening {
                        ProgressView()
                    } else {
                        Text(line.amountLabel(isCredit: isCredit)).font(Typography.amount).moneyLine()
                            .foregroundStyle(isCredit ? Palette.positive : Palette.ink)
                    }
                    if let original = line.originalLabel {
                        Text(original).font(Typography.caption).moneyLine().foregroundStyle(Palette.muted)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
