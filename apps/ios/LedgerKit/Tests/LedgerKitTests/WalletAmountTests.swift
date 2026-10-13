import Foundation
import Testing
@testable import LedgerKit

private func dec(_ s: String) -> Decimal { LedgerDecimal.parse(s)! }
private let enAE = Locale(identifier: "en_AE")
private let enUS = Locale(identifier: "en_US")
private let deDE = Locale(identifier: "de_DE")
private let enGB = Locale(identifier: "en_GB")
private let arAE = Locale(identifier: "ar_AE")
private let arSA = Locale(identifier: "ar_SA")

@Suite("Log Card Payment — the currency comes with the Wallet amount")
struct WalletAmountTests {
    @Test("reads the amount and its currency from the formatted text", arguments: [
        ("AED 12.50", enAE, "12.50", "AED"),
        ("AED12.50", enAE, "12.50", "AED"),
        ("12.50 AED", enAE, "12.50", "AED"),
        ("AED 1,234.50", enAE, "1234.50", "AED"),
        ("US$ 6.25", enAE, "6.25", "USD"),
        ("$6.25", enUS, "6.25", "USD"),
        ("$6.25", enAE, "6.25", "USD"),         // as an en_AE phone writes dollars
        ("US$6.25", enGB, "6.25", "USD"),
        ("€4.20", enAE, "4.20", "EUR"),
        ("12,50 €", deDE, "12.50", "EUR"),
        ("1.234,50 €", deDE, "1234.50", "EUR"),
        ("£3", enAE, "3", "GBP"),
        ("₹ 1,20,000.00", enAE, "120000.00", "INR"),
        ("KWD 1.250", enAE, "1.250", "KWD"),
        ("\u{200F}1,234.50 \u{062F}.\u{0625}.\u{200F}", Locale(identifier: "ar_AE"), "1234.50", "AED"),
        ("\u{062F}.\u{0625}.\u{200F} \u{0661}\u{0662}\u{066B}\u{0665}\u{0660}", Locale(identifier: "ar_AE"), "12.50", "AED"),
        ("usd 7", enAE, "7", "USD"),
    ])
    func parses(text: String, locale: Locale, amount: String, currency: String) throws {
        let parsed = try #require(WalletAmountText.parse(text, locale: locale))
        #expect(parsed.amount == dec(amount))
        #expect(parsed.currency == currency)
    }

    @Test("a refund's minus sign is kept, so the check refuses it as before")
    func negative() throws {
        let parsed = try #require(WalletAmountText.parse("-AED 5.00", locale: enAE))
        #expect(parsed.amount == dec("-5.00"))
        #expect(WalletAmount.resolve(text: "−AED 5.00", fallbackCurrency: nil, locale: enAE)
            .map(\.amount) == .success(dec("-5.00")))
    }

    @Test("one separator with three digits after it: the locale decides")
    func ambiguousGrouping() {
        #expect(WalletAmountText.parse("1,234", locale: enAE)?.amount == dec("1234"))
        #expect(WalletAmountText.parse("1,234", locale: deDE)?.amount == dec("1.234"))
        #expect(WalletAmountText.parse("1.234.567", locale: enAE)?.amount == dec("1234567"))
    }

    @Test("no currency in the text, or a symbol several currencies use: none is guessed", arguments: [
        ("12.50", enAE, false), ("$6.25", enGB, true), ("¥500", enGB, true), ("₿ 5", enAE, true),
    ])
    func noCurrency(text: String, locale: Locale, marked: Bool) throws {
        let parsed = try #require(WalletAmountText.parse(text, locale: locale))
        #expect(parsed.currency == nil)
        #expect(parsed.hasCurrencyMarker == marked)
    }

    // MARK: - Arabic-locale phones

    @Test("Arabic-locale symbols with their bidi marks and trailing dot resolve; ٫ is the decimal point", arguments: [
        // ar_AE writes Western digits.
        ("\u{200F}12.500\u{00A0}\u{062F}.\u{0643}.\u{200F}", arAE, "12.500", "KWD"),
        ("\u{200F}1,234.567\u{00A0}\u{062F}.\u{0628}.\u{200F}", arAE, "1234.567", "BHD"),
        ("\u{200F}1,234.57\u{00A0}\u{062C}.\u{0645}.\u{200F}", arAE, "1234.57", "EGP"),
        ("\u{0631}.\u{0639}. 3.250", arAE, "3.250", "OMR"),
        ("\u{062F}.\u{0623}. 7.125", arAE, "7.125", "JOD"),
        // ar_SA writes Arabic-Indic digits, ٬ for grouping and ٫ for the decimal point.
        ("\u{0661}\u{066B}\u{0662}\u{0663}\u{0664} \u{062F}.\u{0643}.", arSA, "1.234", "KWD"),
        ("\u{200F}\u{0661}\u{066C}\u{0662}\u{0663}\u{0664}\u{066B}\u{0665}\u{0666}\u{0667}\u{00A0}\u{062F}.\u{0643}.\u{200F}",
         arSA, "1234.567", "KWD"),
        ("\u{200F}\u{0662}\u{0665}\u{066B}\u{0665}\u{0660}\u{0660}\u{00A0}\u{062F}.\u{0628}.\u{200F}", arSA, "25.500", "BHD"),
        ("\u{200F}\u{0661}\u{066C}\u{0662}\u{0663}\u{0664}\u{066B}\u{0665}\u{0667}\u{00A0}\u{062C}.\u{0645}.\u{200F}",
         arSA, "1234.57", "EGP"),
        // ٬ with three digits after it is grouping in ar_SA, as , is in ar_AE.
        ("\u{0661}\u{066C}\u{0662}\u{0663}\u{0664} \u{062C}.\u{0645}.", arSA, "1234", "EGP"),
    ])
    func arabicLocales(text: String, locale: Locale, amount: String, currency: String) throws {
        let parsed = try #require(WalletAmountText.parse(text, locale: locale))
        #expect(parsed.amount == dec(amount))
        #expect(parsed.currency == currency)
        #expect(WalletAmount.resolve(text: text, fallbackCurrency: "AED", locale: locale)
                == .success(.init(amount: dec(amount), currency: currency, source: .text)))
    }

    @Test("whatever these Arabic locales write for a Gulf or Levant currency reads back as that currency",
          arguments: ["ar_AE", "ar_SA", "ar_KW", "ar_EG"])
    func arabicRoundTrip(identifier: String) throws {
        let locale = Locale(identifier: identifier)
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        for code in ["KWD", "BHD", "OMR", "JOD", "EGP", "AED", "SAR", "QAR"] {
            formatter.currencyCode = code
            let text = try #require(formatter.string(from: NSDecimalNumber(string: "1234.5")))
            let parsed = try #require(WalletAmountText.parse(text, locale: locale), "\(identifier) \(code)")
            #expect(parsed.currency == code, "\(identifier) \(code)")
            #expect(parsed.amount == dec("1234.5"), "\(identifier) \(code)")
        }
    }

    @Test("the symbol key drops bidi marks and spaces and trims the dots, for the table and the text alike")
    func symbolKey() {
        #expect(WalletAmountText.symbolKey("\u{062F}.\u{0643}.\u{200F}") == "\u{062F}.\u{0643}")
        #expect(WalletAmountText.symbolKey(" \u{062F}.\u{0643}. ") == "\u{062F}.\u{0643}")
        #expect(WalletAmountText.symbolKey("US $") == "US$")
        #expect(WalletAmountText.symbolKey(" . ") == "")
    }

    @Test("not an amount", arguments: ["", "AED", "twelve", "12.50.AB3", "1/2"])
    func notAnAmount(text: String) {
        #expect(WalletAmountText.parse(text, locale: enAE) == nil)
    }

    // MARK: - Which source wins

    @Test("the amount's own currency wins over the fallback")
    func ownCurrencyWins() {
        let r = WalletAmount.resolve(text: "€4.20", fallbackCurrency: "AED", locale: enAE)
        #expect(r == .success(.init(amount: dec("4.20"), currency: "EUR", source: .text)))
    }

    @Test("an amount without a currency takes the fallback, uppercased")
    func fallback() {
        let r = WalletAmount.resolve(text: "12.50", fallbackCurrency: " aed ", locale: enAE)
        #expect(r == .success(.init(amount: dec("12.50"), currency: "AED", source: .fallbackCurrency)))
    }

    @Test("a symbol that is ambiguous or unknown is refused, never filled in from the fallback", arguments: [
        ("$6.25", enGB), ("¥500", enGB), ("₿ 5", enAE), ("12.50 XYZ", enAE), ("\u{0634}.\u{0634}. 12", arAE),
    ])
    func markedButUnresolved(text: String, locale: Locale) {
        #expect(WalletAmount.resolve(text: text, fallbackCurrency: "AED", locale: locale) == .failure(.ambiguousCurrency))
        #expect(WalletAmount.resolve(text: text, fallbackCurrency: nil, locale: locale) == .failure(.ambiguousCurrency))
        #expect(WalletCapture.Problem.ambiguousCurrency.userMessage.contains("won't guess"))
    }

    @Test("no currency anywhere, or an invalid fallback: refused, nothing guessed", arguments: [
        nil, "", "dirham", "AE1",
    ] as [String?])
    func invalidFallback(fallback: String?) {
        let r = WalletAmount.resolve(text: "12.50", fallbackCurrency: fallback, locale: enAE)
        #expect(r == .failure(.invalidCurrency))
    }

    @Test("garbled text or nothing at all is refused")
    func refused() {
        #expect(WalletAmount.resolve(text: "free", fallbackCurrency: "AED") == .failure(.invalidAmount))
        #expect(WalletAmount.resolve(text: nil, fallbackCurrency: "AED") == .failure(.missingAmount))
    }
}

@Suite("Log Card Payment — text amount through the intake")
struct WalletIntakeAmountTests {
    let personal = SMSTarget(profileCode: "prf_personal", name: "Personal")

    func intake(_ api: StubAPI) -> WalletIntake {
        WalletIntake(outbox: Outbox(fileURL: temporaryOutboxURL(), api: api), target: { [personal] in personal })
    }

    @Test("a payment abroad is sent in its own currency")
    func abroad() async throws {
        let api = StubAPI(.succeed(status: "created"))
        let (outcome, dialog) = await intake(api).handle(amountText: "€4.20", fallbackCurrency: nil,
                                                         merchant: "Café", card: "Wio", locale: enAE)
        #expect(outcome == .delivered(status: "created"))
        #expect(dialog == "Logged to Personal.")
        let item = try #require(api.walletCalls.first?.items.first)
        #expect(item.currency == "EUR")
        #expect(item.amount == dec("4.20"))
    }

    @Test("no currency: refused before anything is queued, and the line says what to set")
    func noCurrency() async {
        let api = StubAPI(.succeed(status: "created"))
        let (outcome, dialog) = await intake(api).handle(amountText: "12.50", fallbackCurrency: nil,
                                                         merchant: "Shop", card: "Wio", locale: enAE)
        #expect(outcome == .refused(code: "invalid_currency", message: WalletCapture.Problem.invalidCurrency.userMessage))
        #expect(dialog.contains("Currency if missing"))
        #expect(api.walletCalls.isEmpty)
    }
}
