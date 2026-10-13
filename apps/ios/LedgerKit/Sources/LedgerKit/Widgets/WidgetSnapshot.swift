import Foundation

/// What the Home and Lock Screen widgets show, written by the app to the App
/// Group after Overview loads the current month (BACKLOG N-2). The widget
/// extension reads only this file: no network, no session.
///
/// Every figure is the server's (`rpc('overview')`), copied, never derived on
/// the device (CLAUDE.md §2.2). Money is encoded as decimal strings, like the wire.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    /// Bumped when the shape changes; a widget reading an unknown version shows
    /// "open the app" rather than misreading it.
    public static let currentVersion = 1

    public let version: Int
    public let generatedAt: Date
    /// The ledger on screen when Overview loaded.
    public let profileCode: String
    public let ledgerName: String?
    /// The first day of the month the figures are for.
    public let month: CalendarDay
    /// Posted spend so far this month (`overview.spend`).
    public let spend: Decimal
    /// `overview.spend_prev_month_to_date` and the server's ratio against it.
    public let spendPrevMonthToDate: Decimal
    public let changeVsPrevMonthToDate: Decimal?
    public let uncategorizedCount: Int
    public let cards: [Card]

    /// One card account: its latest statement's due date, balance and
    /// payment status, and utilisation.
    public struct Card: Codable, Sendable, Equatable, Identifiable {
        public var id: String { accountCode }
        public let accountCode: String
        public let title: String
        public let dueDate: CalendarDay?
        public let closingBalance: Decimal?
        public let minDue: Decimal?
        /// The server's latest statement balance / limit (4dp).
        public let utilisation: Decimal?
        /// The latest statement's `payment_status` (`paid | part_paid | unpaid |
        /// overdue`). Absent from an older server, and from a snapshot written
        /// before it was kept: then the phone never claims it was paid.
        public let paymentStatus: String?
        /// Paid towards the latest statement (AED), when the server says.
        public let amountPaid: Decimal?

        public init(accountCode: String, title: String, dueDate: CalendarDay?, closingBalance: Decimal?,
                    minDue: Decimal?, utilisation: Decimal?, paymentStatus: String? = nil,
                    amountPaid: Decimal? = nil) {
            self.accountCode = accountCode
            self.title = title
            self.dueDate = dueDate
            self.closingBalance = closingBalance
            self.minDue = minDue
            self.utilisation = utilisation
            self.paymentStatus = paymentStatus
            self.amountPaid = amountPaid
        }

        /// The server's verdict on the latest statement (`DueStatus`).
        public var duePayment: DuePayment? { DuePayment(status: paymentStatus, amountPaid: amountPaid) }

        enum CodingKeys: String, CodingKey {
            case accountCode, title, dueDate, closingBalance, minDue, utilisation, paymentStatus, amountPaid
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            accountCode = try c.decode(String.self, forKey: .accountCode)
            title = try c.decode(String.self, forKey: .title)
            dueDate = try c.decodeIfPresent(CalendarDay.self, forKey: .dueDate)
            closingBalance = try c.decodeIfPresent(Decimal.self, forKey: .closingBalance)
            minDue = try c.decodeIfPresent(Decimal.self, forKey: .minDue)
            utilisation = try c.decodeIfPresent(Decimal.self, forKey: .utilisation)
            // Snapshots written before these were kept still decode.
            paymentStatus = try c.decodeIfPresent(String.self, forKey: .paymentStatus)
            amountPaid = try c.decodeIfPresent(Decimal.self, forKey: .amountPaid)
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(accountCode, forKey: .accountCode)
            try c.encode(title, forKey: .title)
            try c.encodeIfPresent(dueDate, forKey: .dueDate)
            try c.encodeIfPresent(closingBalance.map(DecimalValue.init), forKey: .closingBalance)
            try c.encodeIfPresent(minDue.map(DecimalValue.init), forKey: .minDue)
            try c.encodeIfPresent(utilisation.map(DecimalValue.init), forKey: .utilisation)
            try c.encodeIfPresent(paymentStatus, forKey: .paymentStatus)
            try c.encodeIfPresent(amountPaid.map(DecimalValue.init), forKey: .amountPaid)
        }
    }

    public init(version: Int = WidgetSnapshot.currentVersion, generatedAt: Date, profileCode: String,
                ledgerName: String?, month: CalendarDay, spend: Decimal, spendPrevMonthToDate: Decimal,
                changeVsPrevMonthToDate: Decimal?, uncategorizedCount: Int, cards: [Card]) {
        self.version = version
        self.generatedAt = generatedAt
        self.profileCode = profileCode
        self.ledgerName = ledgerName
        self.month = month
        self.spend = spend
        self.spendPrevMonthToDate = spendPrevMonthToDate
        self.changeVsPrevMonthToDate = changeVsPrevMonthToDate
        self.uncategorizedCount = uncategorizedCount
        self.cards = cards
    }

    /// The snapshot of a loaded Overview, or nil when it is not the current
    /// month: the widgets are about now, so a past month never overwrites them.
    public static func make(overview: Overview, profileCode: String, ledgerName: String?,
                            now: Date = .now) -> WidgetSnapshot? {
        guard overview.isCurrentMonth(today: LedgerDates.today(now: now)) else { return nil }
        return WidgetSnapshot(
            generatedAt: now, profileCode: profileCode, ledgerName: ledgerName, month: overview.month,
            spend: overview.spend, spendPrevMonthToDate: overview.spendPrevMonthToDate,
            changeVsPrevMonthToDate: overview.changeVsPrevMonthToDate,
            uncategorizedCount: overview.uncategorizedCount,
            cards: overview.accounts.map { account in
                Card(accountCode: account.accountCode, title: account.title,
                     dueDate: account.latestStatement?.dueDate,
                     closingBalance: account.latestStatement?.closingBalance,
                     minDue: account.latestStatement?.minDue,
                     utilisation: account.utilisation,
                     paymentStatus: account.latestStatement?.paymentStatus,
                     amountPaid: account.latestStatement?.amountPaid)
            })
    }

    /// The same figures, ignoring when they were written.
    public func sameContent(as other: WidgetSnapshot) -> Bool {
        var mine = self
        mine.generatedAtOverride = other.generatedAt
        return mine == other
    }

    /// Reload the widgets' timelines for this write: when anything they show
    /// changed (a statement's payment status included: a paid statement leaves
    /// the due widget), or the one on disk is over `maxAge` old (its "Updated" time).
    /// Overview reloads on every Realtime change; an identical write within
    /// the half hour costs no widget reload.
    public func needsReload(replacing previous: WidgetSnapshot?, maxAge: TimeInterval = 30 * 60) -> Bool {
        guard let previous else { return true }
        return !sameContent(as: previous) || generatedAt.timeIntervalSince(previous.generatedAt) >= maxAge
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case version, generatedAt, profileCode, ledgerName, month, spend, spendPrevMonthToDate
        case changeVsPrevMonthToDate, uncategorizedCount, cards
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        profileCode = try c.decode(String.self, forKey: .profileCode)
        ledgerName = try c.decodeIfPresent(String.self, forKey: .ledgerName)
        month = try c.decode(CalendarDay.self, forKey: .month)
        spend = try c.decode(Decimal.self, forKey: .spend)
        spendPrevMonthToDate = try c.decode(Decimal.self, forKey: .spendPrevMonthToDate)
        changeVsPrevMonthToDate = try c.decodeIfPresent(Decimal.self, forKey: .changeVsPrevMonthToDate)
        uncategorizedCount = try c.decode(Int.self, forKey: .uncategorizedCount)
        cards = try c.decode([Card].self, forKey: .cards)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(generatedAt, forKey: .generatedAt)
        try c.encode(profileCode, forKey: .profileCode)
        try c.encodeIfPresent(ledgerName, forKey: .ledgerName)
        try c.encode(month, forKey: .month)
        try c.encode(DecimalValue(spend), forKey: .spend)
        try c.encode(DecimalValue(spendPrevMonthToDate), forKey: .spendPrevMonthToDate)
        try c.encodeIfPresent(changeVsPrevMonthToDate.map(DecimalValue.init), forKey: .changeVsPrevMonthToDate)
        try c.encode(uncategorizedCount, forKey: .uncategorizedCount)
        try c.encode(cards, forKey: .cards)
    }

    /// The App Group file's bytes (`LedgerJSON`'s encoder: snake_case keys, ISO timestamps).
    public func encoded() throws -> Data { try LedgerJSON.makeEncoder().encode(self) }

    /// Nil for unreadable bytes or a version this build doesn't know.
    public static func decode(_ data: Data) -> WidgetSnapshot? {
        guard let snapshot = try? LedgerJSON.decode(WidgetSnapshot.self, from: data),
              snapshot.version == currentVersion else { return nil }
        return snapshot
    }
}

extension WidgetSnapshot {
    /// `sameContent` compares everything but the write time.
    fileprivate var generatedAtOverride: Date {
        get { generatedAt }
        set {
            self = WidgetSnapshot(version: version, generatedAt: newValue, profileCode: profileCode,
                                  ledgerName: ledgerName, month: month, spend: spend,
                                  spendPrevMonthToDate: spendPrevMonthToDate,
                                  changeVsPrevMonthToDate: changeVsPrevMonthToDate,
                                  uncategorizedCount: uncategorizedCount, cards: cards)
        }
    }
}
