import Foundation

/// A credit-linked note's terms and what they come to today (`credit`, 20261028110553): a fixed
/// coupon on a schedule (or paid in one go at maturity) for as long as the reference entity has no
/// credit event. No shares, barriers or autocalls. Every figure is the server's
/// (`private.cln_evaluate`); the summary's carries no schedule.
public struct NoteCredit: Decodable, Sendable, Hashable {
    /// Interest earned since the last coupon (or the interest start) and not yet paid.
    public struct Accrued: Decodable, Sendable, Hashable {
        public let amount: Decimal
        public let since: CalendarDay?
    }

    /// One coupon. `status` is raw: `paid`, `to_come`, `before_purchase` (the seller's) or
    /// `not_paid` (after the note ended early).
    public struct Coupon: Decodable, Sendable, Hashable, Identifiable {
        public var id: Int { seq }
        public let seq: Int
        public let periodStart: CalendarDay?
        public let payDate: CalendarDay
        public let ratePct: Decimal
        public let amount: Decimal
        public let isFinal: Bool
        public let isCallDate: Bool
        public let status: String
    }

    /// Held to maturity: every coupon (received and to come) and the face value back.
    public struct ToMaturity: Decodable, Sendable, Hashable {
        public let date: CalendarDay
        public let coupons: Decimal
        public let total: Decimal
        public let profit: Decimal
        public let returnPct: Decimal
        public let annualisedPct: Decimal?
    }

    /// Called at the next call date: 100% plus the coupons and interest up to it.
    public struct IfCalled: Decodable, Sendable, Hashable {
        public let date: CalendarDay
        public let total: Decimal
        public let profit: Decimal
        public let returnPct: Decimal
        public let annualisedPct: Decimal?
    }

    /// What a credit event would cost today: the face value is at the market's recovery, the
    /// interest to come (and, paid at maturity, the accrued) is lost; what was received is kept.
    public struct CreditEvent: Decodable, Sendable, Hashable {
        public let principalAtRisk: Decimal
        public let interestLost: Decimal
        public let accruedLost: Decimal
        public let kept: Decimal
    }

    public let referenceEntity: String
    public let seniority: String?
    public let transactionType: String?
    public let referenceObligationIsin: String?
    /// The coupon, % a year.
    public let couponRatePct: Decimal?
    /// Raw: `monthly`, `quarterly`, `semiannual`, `annual` or `at_maturity`.
    public let couponFrequency: String?
    public let dayCount: String?
    public let interestAtMaturity: Bool
    public let interestStartDate: CalendarDay?
    public let firstCouponDate: CalendarDay?
    public let maturityDate: CalendarDay?
    /// How late it may repay while a credit event is being determined.
    public let longstopMaturityDate: CalendarDay?
    public let callDates: [CalendarDay]
    public let callNoticeDays: Decimal?
    /// Nil once ended or with no call date left.
    public let nextCallDate: CalendarDay?
    public let accrued: Accrued?
    public let remainingCoupons: Decimal?
    /// Empty in the summary.
    public let schedule: [Coupon]
    /// Nil once ended.
    public let toMaturity: ToMaturity?
    public let ifCalledNext: IfCalled?
    public let creditEvent: CreditEvent?

    enum CodingKeys: String, CodingKey {
        case referenceEntity, seniority, transactionType, referenceObligationIsin, couponRatePct, couponFrequency, dayCount
        case interestAtMaturity, interestStartDate, firstCouponDate, maturityDate, longstopMaturityDate, callDates
        case callNoticeDays, nextCallDate, accrued, remainingCoupons, schedule, toMaturity, ifCalledNext, creditEvent
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        referenceEntity = try c.decodeIfPresent(String.self, forKey: .referenceEntity) ?? ""
        seniority = try c.decodeIfPresent(String.self, forKey: .seniority)
        transactionType = try c.decodeIfPresent(String.self, forKey: .transactionType)
        referenceObligationIsin = try c.decodeIfPresent(String.self, forKey: .referenceObligationIsin)
        couponRatePct = try c.decodeIfPresent(Decimal.self, forKey: .couponRatePct)
        couponFrequency = try c.decodeIfPresent(String.self, forKey: .couponFrequency)
        dayCount = try c.decodeIfPresent(String.self, forKey: .dayCount)
        interestAtMaturity = try c.decodeIfPresent(Bool.self, forKey: .interestAtMaturity) ?? (couponFrequency == "at_maturity")
        interestStartDate = try c.decodeIfPresent(CalendarDay.self, forKey: .interestStartDate)
        firstCouponDate = try c.decodeIfPresent(CalendarDay.self, forKey: .firstCouponDate)
        maturityDate = try c.decodeIfPresent(CalendarDay.self, forKey: .maturityDate)
        longstopMaturityDate = try c.decodeIfPresent(CalendarDay.self, forKey: .longstopMaturityDate)
        callDates = try c.decodeIfPresent([CalendarDay].self, forKey: .callDates) ?? []
        callNoticeDays = try c.decodeIfPresent(Decimal.self, forKey: .callNoticeDays)
        nextCallDate = try c.decodeIfPresent(CalendarDay.self, forKey: .nextCallDate)
        accrued = try c.decodeIfPresent(Accrued.self, forKey: .accrued)
        remainingCoupons = try c.decodeIfPresent(Decimal.self, forKey: .remainingCoupons)
        schedule = try c.decodeIfPresent([Coupon].self, forKey: .schedule) ?? []
        toMaturity = try c.decodeIfPresent(ToMaturity.self, forKey: .toMaturity)
        ifCalledNext = try c.decodeIfPresent(IfCalled.self, forKey: .ifCalledNext)
        creditEvent = try c.decodeIfPresent(CreditEvent.self, forKey: .creditEvent)
    }
}
