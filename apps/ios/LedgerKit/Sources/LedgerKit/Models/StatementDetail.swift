import Foundation

/// `rpc('statement_detail')`: one statement with its current debit and credit
/// lines. Money is decimal strings; every header figure is optional because the
/// parser may not have found it on the PDF.
public struct StatementDetail: Decodable, Sendable, Hashable {
    public let statement: Header
    public let debits: Side
    public let credits: Side

    public struct Header: Decodable, Sendable, Hashable {
        public let stmtCode: String
        public let kind: String                // statement | history_extract
        public let bankCode: String?
        public let accountCode: String
        public let cardLast4s: [String]
        public let statementDate: CalendarDay
        public let periodStart: CalendarDay?
        public let periodEnd: CalendarDay?
        public let dueDate: CalendarDay?
        public let openingBalance: Decimal?
        public let closingBalance: Decimal?
        public let totalDebits: Decimal?
        public let totalCredits: Decimal?
        public let minDue: Decimal?
        public let creditLimit: Decimal?
        public let docCode: String?
        public let reconStatus: String?        // ok | warn | fail | n/a
        public let reconChecks: ReconChecks?

        enum CodingKeys: String, CodingKey {
            case stmtCode, kind, bankCode, accountCode, cardLast4s, statementDate, periodStart, periodEnd, dueDate
            case openingBalance, closingBalance, totalDebits, totalCredits, minDue, creditLimit, docCode
            case reconStatus, reconChecks
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            stmtCode = try c.decode(String.self, forKey: .stmtCode)
            kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "statement"
            bankCode = try c.decodeIfPresent(String.self, forKey: .bankCode)
            accountCode = try c.decode(String.self, forKey: .accountCode)
            cardLast4s = (try? c.decodeIfPresent([String].self, forKey: .cardLast4s)) ?? []
            statementDate = try c.decode(CalendarDay.self, forKey: .statementDate)
            periodStart = try c.decodeIfPresent(CalendarDay.self, forKey: .periodStart)
            periodEnd = try c.decodeIfPresent(CalendarDay.self, forKey: .periodEnd)
            dueDate = try c.decodeIfPresent(CalendarDay.self, forKey: .dueDate)
            openingBalance = try c.decodeIfPresent(Decimal.self, forKey: .openingBalance)
            closingBalance = try c.decodeIfPresent(Decimal.self, forKey: .closingBalance)
            totalDebits = try c.decodeIfPresent(Decimal.self, forKey: .totalDebits)
            totalCredits = try c.decodeIfPresent(Decimal.self, forKey: .totalCredits)
            minDue = try c.decodeIfPresent(Decimal.self, forKey: .minDue)
            creditLimit = try c.decodeIfPresent(Decimal.self, forKey: .creditLimit)
            docCode = try c.decodeIfPresent(String.self, forKey: .docCode)
            reconStatus = try c.decodeIfPresent(String.self, forKey: .reconStatus)
            reconChecks = try? c.decodeIfPresent(ReconChecks.self, forKey: .reconChecks)
        }
    }

    /// `debits` / `credits`: the server's count and total for that side.
    public struct Side: Decodable, Sendable, Hashable {
        public let count: Int
        public let total: Decimal
        public let lines: [Line]
    }

    /// One current statement line. `description` is the line as printed;
    /// `merchant_name` and `category_code` come from the linked transaction
    /// (nil when the line is held or unmatched, and then `txn_code` is nil too).
    public struct Line: Decodable, Sendable, Hashable, Identifiable {
        public var id: String { lineCode }
        public let lineCode: String
        public let txnCode: String?
        public let txnDate: CalendarDay
        public let postingDate: CalendarDay?
        public let description: String
        public let merchantName: String?
        public let amountAed: Decimal?
        public let amountOriginal: Decimal?
        public let currencyOriginal: String?
        public let categoryCode: String?
        public let kind: String?
        public let cardLast4: String?

        enum CodingKeys: String, CodingKey {
            case lineCode, txnCode, txnDate, postingDate, description, merchantName, amountAed, amountOriginal
            case currencyOriginal, categoryCode, kind, cardLast4
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            lineCode = try c.decode(String.self, forKey: .lineCode)
            txnCode = try c.decodeIfPresent(String.self, forKey: .txnCode)
            txnDate = try c.decode(CalendarDay.self, forKey: .txnDate)
            postingDate = try c.decodeIfPresent(CalendarDay.self, forKey: .postingDate)
            description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
            merchantName = try c.decodeIfPresent(String.self, forKey: .merchantName)
            amountAed = try c.decodeIfPresent(Decimal.self, forKey: .amountAed)
            amountOriginal = try c.decodeIfPresent(Decimal.self, forKey: .amountOriginal)
            currencyOriginal = try c.decodeIfPresent(String.self, forKey: .currencyOriginal)
            categoryCode = try c.decodeIfPresent(String.self, forKey: .categoryCode)
            kind = try c.decodeIfPresent(String.self, forKey: .kind)
            cardLast4 = try c.decodeIfPresent(String.self, forKey: .cardLast4)
        }
    }
}
