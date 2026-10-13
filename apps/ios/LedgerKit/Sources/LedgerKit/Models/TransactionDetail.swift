import Foundation

/// `rpc('merchant_context')`: what this ledger has spent at a merchant, from
/// `v_spend` (audit MA-4). Every figure is the server's (CLAUDE.md §2.2).
public struct MerchantContext: Decodable, Sendable, Hashable {
    public let merchantCode: String
    /// Purchases at the merchant, all time (refunds are not visits).
    public let visitCount: Int
    /// Their average; nil with no visit.
    public let avgAed: Decimal?
    /// Net spend in the last 6 months.
    public let total6mAed: Decimal
    public let firstSeen: CalendarDay?

    enum CodingKeys: String, CodingKey {
        case merchantCode = "merchant_code"
        case visitCount = "visit_count"
        case avgAed = "avg_aed"
        case total6mAed = "total_6m_aed"
        case firstSeen = "first_seen"
    }

    public init(from decoder: any Decoder) throws {
        let c = try WireKeyedContainer(decoder, keyedBy: CodingKeys.self)
        merchantCode = try c.decode(String.self, forKey: .merchantCode)
        visitCount = try c.decode(Int.self, forKey: .visitCount)
        avgAed = try c.decodeIfPresent(Decimal.self, forKey: .avgAed)
        total6mAed = try c.decode(Decimal.self, forKey: .total6mAed)
        firstSeen = try c.decodeIfPresent(CalendarDay.self, forKey: .firstSeen)
    }

    /// `"13 visits · avg AED 254 · AED 3,306 in 6 months · since 2 Mar 2024"`, the
    /// web drawer's line (`merchantContextLine`); nil with no visit.
    public var line: String? {
        guard visitCount >= 1 else { return nil }
        var parts = [visitCount == 1 ? "First visit"
                     : "\(MoneyFormat.grouped(Decimal(visitCount), fractionDigits: 0)) visits"]
        if visitCount > 1, let avgAed { parts.append("avg \(MoneyFormat.total(avgAed))") }
        if total6mAed != 0 { parts.append("\(MoneyFormat.total(total6mAed)) in 6 months") }
        if visitCount > 1, let firstSeen { parts.append("since \(LedgerDates.fullDayLabel(firstSeen))") }
        return parts.joined(separator: " · ")
    }
}

extension MoneyFormat {
    /// A sum or average in whole dirhams, as the web's `formatTotal`: `"AED 254"`,
    /// `"−AED 40"`; an amount that would round to 0 keeps its fils (`"AED 0.40"`).
    public static func total(_ value: Decimal) -> String {
        let magnitude = value < 0 ? -value : value
        let digits = magnitude != 0 && magnitude < Decimal(string: "0.5")! ? 2 : 0
        return (value < 0 ? "−" : "") + aed(magnitude, fractionDigits: digits)
    }
}

/// One row of `public.transaction_evidence` with the statement line or SMS it
/// points at (never the SMS body: that is read only when the reader asks).
public struct EvidenceItem: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { evidenceCode }
    public let evidenceCode: String
    public let evidenceType: String       // statement_line | history_line | sms
    public let role: String
    public let method: String
    public let score: Decimal?
    public let isActive: Bool
    public let isLocked: Bool
    public let createdAt: Date
    public let statementLines: Line?
    public let smsMessages: SMS?

    public struct Line: Decodable, Sendable, Hashable {
        public let lineCode: String
        public let stmtCode: String
        public let txnDate: CalendarDay
        public let postingDate: CalendarDay?
        public let descriptionRaw: String
        public let amountOriginal: Decimal
        public let currencyOriginal: String
        public let amountAed: Decimal?
        public let statements: Statement?
    }

    public struct Statement: Decodable, Sendable, Hashable {
        public let statementDate: CalendarDay
        public let kind: String
    }

    public struct SMS: Decodable, Sendable, Hashable {
        public let smsCode: String
        public let receivedAt: Date
        public let eventAt: Date?
        public let sender: String
        public let msgKind: String?
        public let amount: Decimal?
        public let currency: String?
        public let cardLast4: String?
    }

    /// The columns the sheet reads, and the embedded rows (PostgREST resource embedding).
    public static let select = "evidence_code,evidence_type,role,method,score,is_active,is_locked,created_at,"
        + "statement_lines(line_code,stmt_code,txn_date,posting_date,description_raw,amount_original,"
        + "currency_original,amount_aed,statements(statement_date,kind)),"
        + "sms_messages(sms_code,received_at,event_at,sender,msg_kind,amount,currency,card_last4)"

    // MARK: Words (the web drawer's EVIDENCE_LABEL, ROLE_LABEL, METHOD_LABEL)

    public var isSMS: Bool { smsMessages != nil }

    public var title: String {
        switch evidenceType {
        case "statement_line": "Statement line"
        case "history_line": "History export line"
        case "sms": "Bank SMS"
        default: evidenceType
        }
    }

    public var roleLabel: String {
        switch role {
        case "primary": "created the transaction"
        case "auth": "authorisation"
        case "post": "posted"
        case "reversal": "reversal"
        case "duplicate": "duplicate alert"
        default: role
        }
    }

    /// `"exact match"`, `"scored match (85)"`.
    public var methodLabel: String {
        let words = switch method {
        case "new": "new"
        case "exact": "exact match"
        case "scored": "scored match"
        case "tie": "identical twin"
        case "manual": "linked by you"
        case "legacy": "imported"
        default: method
        }
        guard let score, method != "new" else { return words }
        return "\(words) (\(MoneyFormat.grouped(score, fractionDigits: 0)))"
    }

    /// When the evidence happened: the SMS's time, else the line's posting or transaction date.
    public var happenedAt: Date {
        if let sms = smsMessages { return sms.eventAt ?? sms.receivedAt }
        if let line = statementLines { return (line.postingDate ?? line.txnDate).startDate }
        return createdAt
    }

    /// `"8 Oct 2026, 14:05 · exact match"` for an SMS, `"8 Oct 2026 · scored match (85)"` for a line.
    public var whenLabel: String {
        let when: String
        if let sms = smsMessages {
            when = LedgerDates.dateTimeLabel(sms.eventAt ?? sms.receivedAt)
        } else if let line = statementLines {
            when = LedgerDates.fullDayLabel(line.postingDate ?? line.txnDate)
        } else {
            when = LedgerDates.dateTimeLabel(createdAt)
        }
        return "\(when) · \(methodLabel)"
    }

    /// `"USD 12.00 → AED 44.07 · statement of 1 Sep 2026"`.
    public var lineSummary: String? {
        guard let line = statementLines else { return nil }
        var text = MoneyFormat.amount(line.amountOriginal, currency: line.currencyOriginal)
        if line.currencyOriginal != "AED", let aed = line.amountAed { text += " → \(MoneyFormat.aed(aed))" }
        if let s = line.statements {
            text += " · \(s.kind == "statement" ? "statement" : "history export") of \(LedgerDates.fullDayLabel(s.statementDate))"
        }
        return text
    }

    /// `"From FAB · received 8 Oct 2026, 14:05"`.
    public var smsHeader: String? {
        smsMessages.map { "From \($0.sender) · received \(LedgerDates.dateTimeLabel($0.receivedAt))" }
    }

    /// `"AED 45.00 · purchase · •1234"`; nil when the SMS had no amount.
    public var smsDetail: String? {
        guard let sms = smsMessages, let amount = sms.amount else { return nil }
        var parts = [MoneyFormat.amount(amount, currency: sms.currency ?? "AED")]
        if let kind = sms.msgKind { parts.append(kind) }
        if let last4 = sms.cardLast4 { parts.append("•\(last4)") }
        return parts.joined(separator: " · ")
    }

    /// Timeline order, as the web's `sortEvidence`: attached first, then oldest first.
    public static func sorted(_ items: [EvidenceItem]) -> [EvidenceItem] {
        items.sorted { a, b in
            if a.isActive != b.isActive { return a.isActive }
            return a.happenedAt < b.happenedAt
        }
    }
}

/// A badge on the detail sheet.
public struct DetailBadge: Hashable, Sendable {
    public let label: String
    public let tone: Tone
}

extension LedgerTransaction {
    /// No AED amount yet for a foreign charge: the amount shows in its own currency.
    public var awaitingFx: Bool { amountAed == nil && currencyOriginal != "AED" }

    /// The web drawer's badges: status, kind, where the evidence came from, the
    /// FX state and the spend exclusion.
    public var detailBadges: [DetailBadge] {
        let statusTone: Tone = switch status {
        case "pending": .warn
        case "orphaned": .danger
        default: .neutral
        }
        var out = [DetailBadge(label: status.capitalized, tone: statusTone),
                   DetailBadge(label: kind.replacingOccurrences(of: "_", with: " ").capitalized, tone: .neutral)]
        switch (hasSms, hasStatement) {
        case (true, true): out.append(DetailBadge(label: "SMS + statement", tone: .neutral))
        case (true, false): out.append(DetailBadge(label: "SMS", tone: .neutral))
        case (false, true): out.append(DetailBadge(label: "Statement", tone: .neutral))
        case (false, false): break
        }
        if awaitingFx { out.append(DetailBadge(label: "Awaiting FX rate", tone: .warn)) }
        if amountAedIsEstimate { out.append(DetailBadge(label: "AED estimated", tone: .warn)) }
        if excludeFromSpend { out.append(DetailBadge(label: "Excluded from spend", tone: .info)) }
        return out
    }

    /// `"8 Oct 2026, 14:05"` when the time is known, else `"8 Oct 2026"`.
    public var whenLabel: String { txnAt.map(LedgerDates.dateTimeLabel) ?? LedgerDates.fullDayLabel(txnDate) }

    public var postedLabel: String? { postingDate.map(LedgerDates.fullDayLabel) }

    /// `"FAB •1234 · Daily card"`.
    public var cardDetail: String { [cardLabel, accountNickname].compactMap { $0 }.joined(separator: " · ") }

    /// `"USD 12.00 @ 3.6725"` for a foreign charge (the server's rate, 4 places), else nil.
    public var foreignAmountLine: String? {
        guard currencyOriginal != "AED" else { return nil }
        let amount = MoneyFormat.amount(amountOriginal, currency: currencyOriginal)
        return fxRate.map { "\(amount) @ \(MoneyFormat.grouped($0, fractionDigits: 4))" } ?? amount
    }

    /// `"USD 12.00 at the time of the SMS"` when the alert's amount was kept.
    public var authorisedLine: String? {
        authAmount.map { "\(MoneyFormat.amount($0, currency: currencyOriginal)) at the time of the SMS" }
    }

    /// The reversal section's title: this row reverses another, or another reverses it.
    public var relatedTitle: String { relatedTxnCode != nil ? "Reverses" : "Reversed by" }
}
