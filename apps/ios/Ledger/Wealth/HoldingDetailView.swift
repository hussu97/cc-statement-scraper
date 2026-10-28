import LedgerKit
import SwiftUI

/// One holding (pushed from Investments): its value and gain as the tab shows them, its returns
/// for every period, its recorded values with Update value, and its money in and out, a linked
/// payment naming its description and bank. Owners add a flow, swipe one to remove it (or unlink
/// its payment), update the value and edit or close the holding. `HoldingDetailModel` decides.
struct HoldingDetailView: View {
    let investments: InvestmentsModel
    let holdingCode: String
    let profileCode: String
    let canEdit: Bool
    /// @State, not let: kept across the parent's re-renders, so loaded flows aren't thrown away.
    @State private var model: HoldingDetailModel
    @State private var editing: HoldingDraft?
    @State private var addingFlow: FlowDraft?
    @State private var updating: ValueDraft?
    @State private var error: String?
    @State private var period: ReturnsPeriod = .all
    @State private var showAllValues = false
    @Environment(\.dismiss) private var dismiss
    @Environment(BankCatalog.self) private var catalog: BankCatalog?

    init(investments: InvestmentsModel, holdingCode: String, profileCode: String, canEdit: Bool) {
        self.investments = investments
        self.holdingCode = holdingCode
        self.profileCode = profileCode
        self.canEdit = canEdit
        _model = State(initialValue: investments.detailModel(for: holdingCode))
    }

    private var holding: Holding? { investments.holding(holdingCode) }

    var body: some View {
        Group {
            if let holding {
                list(holding)
            } else {
                EmptyCard(systemImage: "tray", message: "This holding is closed or no longer in the ledger.")
                    .padding(Metrics.gutter)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .background(Palette.bg)
        .ledgerNavigation(holding?.name ?? "Holding")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canEdit, let holding {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = investments.draft(for: holding) }
                }
            }
        }
        .sheet(item: $editing) { draft in
            HoldingSheet(model: investments, draft: draft, original: holding, profileCode: profileCode, canEdit: canEdit)
        }
        .sheet(item: $addingFlow) { draft in
            AddFlowSheet(model: model, draft: draft, profileCode: profileCode, canEdit: canEdit)
        }
        .sheet(item: $updating) { draft in
            UpdateValueSheet(model: model, draft: draft, profileCode: profileCode, canEdit: canEdit)
        }
        .alert("Couldn't change it", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
        .task { await model.loadIfNeeded(profileCode: profileCode) }
        .refreshable {
            await model.load(profileCode: profileCode)
            await investments.refresh(profileCode: profileCode)
        }
        // Closed from its Edit sheet: back to the list.
        .onChange(of: holding == nil) { _, gone in
            if gone, investments.state.value != nil, !investments.state.isLoading { dismiss() }
        }
    }

    private func list(_ holding: Holding) -> some View {
        List {
            Section {
                summary(holding)
                if let notice = model.notice {
                    Label(notice.text, systemImage: "checkmark.circle")
                        .font(Typography.rowMeta).foregroundStyle(Palette.positive)
                }
            }
            Section {
                Picker("Period", selection: $period) {
                    ForEach(ReturnsPeriod.holding) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                PeriodReturnRow(period: period, state: model.returns[period])
            } header: {
                Text("Returns")
            }
            if model.showsValueHistory(for: holding) { valuesSection(holding) }
            if holding.kind.takesFlows || !model.flows.isEmpty { flowsSection(holding) }
        }
        .scrollContentBackground(.hidden)
    }

    private func summary(_ holding: Holding) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                HoldingThumbnail(holding: holding, supabaseURL: catalog?.supabaseURL, side: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(holding.valueText).font(Typography.amountLarge).foregroundStyle(Palette.ink).moneyLine()
                    if let own = holding.ownValueText {
                        Text(own).font(Typography.rowMeta).foregroundStyle(Palette.muted).moneyLine()
                    }
                }
            }
            Text(holding.detail).font(Typography.rowMeta).foregroundStyle(Palette.muted)
            HStack(spacing: 8) {
                Text(holding.gainText ?? holding.noGainText).font(Typography.rowMeta)
                    .foregroundStyle(holding.gainText == nil ? Palette.muted : holding.gainTone.color)
                if let estimate = holding.estimateLabel { Chip(label: estimate, tone: .info) }
            }
            if let cost = holding.costAed {
                Text("Put in " + MoneyFormat.aed(cost) + (holding.incomeText.map { " · \($0)" } ?? ""))
                    .font(Typography.caption).foregroundStyle(Palette.muted)
            }
            if let asOf = holding.asOfText() { Text(asOf).font(Typography.caption).foregroundStyle(Palette.muted) }
            if let rate = investments.state.value?.valuation.rate(for: holding) { MetalRateLine(rate: rate) }
            if let stale = holding.staleText() {
                Label(stale, systemImage: "clock.badge.exclamationmark").font(Typography.caption).foregroundStyle(Palette.warn)
            }
            if let rule = holding.linkRuleText {
                Label(rule, systemImage: "link")
                    .font(Typography.caption).foregroundStyle(Palette.muted)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func valuesSection(_ holding: Holding) -> some View {
        Section {
            if canEdit, holding.canRecordValue {
                Button {
                    updating = model.newValue(for: holding)
                } label: {
                    Label(holding.kind == .security ? "Update price" : "Update value", systemImage: "pencil.line")
                }
                .tint(Palette.accent)
            }
            if let empty = model.noValuesMessage(for: holding) {
                Text(empty).font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
            let values = HoldingValuationRecord.visible(model.valuations, showAll: showAllValues)
            ForEach(values.shown) { v in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LedgerDates.fullDayLabel(v.asOf)).font(Typography.rowMeta).foregroundStyle(Palette.ink)
                        if let source = v.sourceLabel(for: holding.kind) {
                            Text(source).font(Typography.rowMeta).foregroundStyle(Palette.muted)
                        }
                    }
                    Spacer()
                    Text(v.text(currency: holding.currency)).font(Typography.amount).foregroundStyle(Palette.ink).moneyLine()
                }
                .accessibilityElement(children: .combine)
            }
            if values.hidden > 0 {
                Button("Show all \(model.valuations.count) values") { showAllValues = true }
                    .tint(Palette.accent)
            }
        } header: {
            Text(holding.kind == .security ? "Price history" : "Value history")
        }
    }

    private func flowsSection(_ holding: Holding) -> some View {
        Section {
            if canEdit, holding.kind.takesFlows {
                Button { addingFlow = model.newFlow(for: holding) } label: {
                    Label("Add money in or out", systemImage: "plus.circle")
                }
                .tint(Palette.accent)
            }
            if model.detail.value == nil, let message = model.detail.errorMessage {
                Text(message).font(Typography.rowMeta).foregroundStyle(Palette.danger)
            } else if model.detail.value == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
            if let empty = model.noFlowsMessage(for: holding) {
                Text(empty).font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
            ForEach(model.flows) { flow in
                FlowRow(flow: flow, currency: holding.currency)
                    .swipeActions(edge: .trailing) {
                        if canEdit, flow.canRemove {
                            Button(flow.removeTitle, role: .destructive) { remove(flow) }
                        }
                    }
            }
        } header: {
            Text("Money in and out")
        } footer: {
            if canEdit, model.flows.contains(where: \.canRemove) {
                Text("Swipe a row to remove it. Unlinking a payment makes it spending again; the payment rule won't link it back.")
            }
        }
    }

    private func remove(_ flow: HoldingFlow) {
        Task {
            if let problem = await model.remove(flow, profileCode: profileCode, canEdit: canEdit) { error = problem }
        }
    }
}

/// One period's returns for this holding: growth, the yearly rate, and money added.
private struct PeriodReturnRow: View {
    let period: ReturnsPeriod
    let state: LoadState<HoldingReturn?>?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let row = state?.value, let row {
                if row.figures.complete {
                    ReturnFiguresView(figures: row.figures, period: period)
                } else {
                    Text(HoldingReturn.incompleteNote(period: period)).font(Typography.caption).foregroundStyle(Palette.muted)
                }
            } else if let message = state?.errorMessage {
                Text(message).font(Typography.caption).foregroundStyle(Palette.danger)
            } else if state?.isLoading ?? true {
                ProgressView()
            } else {
                Text("No figures for this period.").font(Typography.caption).foregroundStyle(Palette.muted)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A flow: the payment's description (or note, or kind), how it got here, the amount in the
/// holding's currency and, for a foreign one, in AED.
private struct FlowRow: View {
    let flow: HoldingFlow
    let currency: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let bank = flow.txnBankCode {
                BankLogo(bankCode: bank, size: 24)
            } else {
                Image(systemName: flow.source == "holding_cost" ? "tag" : "hand.point.up.left")
                    .foregroundStyle(Palette.muted).frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(flow.title).font(Typography.rowTitle).foregroundStyle(Palette.ink).lineLimit(2)
                Text(flow.caption).font(Typography.caption).foregroundStyle(Palette.muted)
                Text(LedgerDates.fullDayLabel(flow.flowDate)).font(Typography.caption).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(flow.amountText(currency: currency)).font(Typography.amount).moneyLine()
                    .foregroundStyle(flow.amountTone == .positive ? Palette.positive : Palette.ink)
                if let aed = flow.aedText(currency: currency) {
                    Text(aed).font(Typography.caption).foregroundStyle(Palette.muted).moneyLine()
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// The Dubai retail rate a metal is valued at, per gram, with its 24-hour move and as of when.
private struct MetalRateLine: View {
    let rate: (title: String, quote: MetalQuote, price: MetalPrice)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(rate.title).font(Typography.caption).foregroundStyle(Palette.muted)
                if rate.price.isStale { Chip(label: "Stale", tone: .warn) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(HoldingsText.perGram(rate.price.aedPerGram)).font(Typography.rowMeta).foregroundStyle(Palette.ink)
                    .monospacedDigit()
                if let change = rate.price.changeText {
                    Text("\(change) in 24h").font(Typography.caption).foregroundStyle(rate.price.changeTone.color)
                }
            }
            Text(rate.price.asOfText()).font(Typography.caption).foregroundStyle(Palette.muted)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radiusMd))
        .overlay(RoundedRectangle(cornerRadius: Metrics.radiusMd).stroke(Palette.border, lineWidth: 0.5))
    }
}
