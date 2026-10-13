import Foundation
import Testing
@testable import LedgerKit

private func dec(_ s: String) -> Decimal { LedgerDecimal.parse(s)! }
private let enAE = Locale(identifier: "en_AE")
private let enUS = Locale(identifier: "en_US")
private let deDE = Locale(identifier: "de_DE")
private let enGB = Locale(identifier: "en_GB")

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
        #expect(WalletAmount.resolve(text: "−AED 5.00", currencyAmount: nil, fallbackCurrency: nil, locale: enAE)
            .map(\.amount) == .success(dec("-5.00")))
    }

    @Test("one separator with three digits after it: the locale decides")
    func ambiguousGrouping() {
        #expect(WalletAmountText.parse("1,234", locale: enAE)?.amount == dec("1234"))
        #expect(WalletAmountText.parse("1,234", locale: deDE)?.amount == dec("1.234"))
        #expect(WalletAmountText.parse("1.234.567", locale: enAE)?.amount == dec("1234567"))
    }

    @Test("no currency in the text, or a symbol several currencies use: none is guessed", arguments: [
        ("12.50", enAE), ("$6.25", enGB), ("¥500", enGB),
    ])
    func noCurrency(text: String, locale: Locale) throws {
        let parsed = try #require(WalletAmountText.parse(text, locale: locale))
        #expect(parsed.currency == nil)
    }

    @Test("not an amount", arguments: ["", "AED", "twelve", "12.50.AB3", "1/2"])
    func notAnAmount(text: String) {
        #expect(WalletAmountText.parse(text, locale: enAE) == nil)
    }

    // MARK: - Which source wins

    @Test("the amount's own currency wins over the fallback and the older fixed currency")
    func ownCurrencyWins() {
        let r = WalletAmount.resolve(text: "€4.20", currencyAmount: (dec("4.20"), "AED"),
                                     fallbackCurrency: "AED", locale: enAE)
        #expect(r == .success(.init(amount: dec("4.20"), currency: "EUR", source: .text)))
    }

    @Test("an amount without a currency takes the fallback, uppercased")
    func fallback() {
        let r = WalletAmount.resolve(text: "12.50", currencyAmount: nil, fallbackCurrency: " aed ", locale: enAE)
        #expect(r == .success(.init(amount: dec("12.50"), currency: "AED", source: .textWithFallbackCurrency)))
    }

    @Test("without a fallback, the older parameter's currency fills in")
    func fallbackFromCurrencyAmount() {
        let r = WalletAmount.resolve(text: "12.50", currencyAmount: (dec("99"), "AED"), fallbackCurrency: nil, locale: enAE)
        #expect(r == .success(.init(amount: dec("12.50"), currency: "AED", source: .textWithFallbackCurrency)))
    }

    @Test("no currency anywhere, or an invalid fallback: refused, nothing guessed", arguments: [
        nil, "", "dirham", "AE1",
    ] as [String?])
    func invalidFallback(fallback: String?) {
        let r = WalletAmount.resolve(text: "12.50", currencyAmount: nil, fallbackCurrency: fallback, locale: enAE)
        #expect(r == .failure(.invalidCurrency))
    }

    @Test("automations set up with the currency amount keep working, in its own currency")
    func olderAutomation() {
        let r = WalletAmount.resolve(text: nil, currencyAmount: (dec("45.10"), "usd"), fallbackCurrency: "AED", locale: enAE)
        #expect(r == .success(.init(amount: dec("45.10"), currency: "USD", source: .currencyAmount)))
        let empty = WalletAmount.resolve(text: "  ", currencyAmount: (dec("1"), ""), fallbackCurrency: "EUR", locale: enAE)
        #expect(empty == .success(.init(amount: dec("1"), currency: "EUR", source: .currencyAmount)))
    }

    @Test("the untouched older field (Shortcuts shows it as 0 AED) is neither an amount nor a currency")
    func untouchedDefault() {
        #expect(WalletAmount.resolve(text: nil, currencyAmount: (0, "AED"), fallbackCurrency: nil, locale: enAE)
                == .failure(.missingAmount))
        #expect(WalletAmount.resolve(text: "12.50", currencyAmount: (0, "AED"), fallbackCurrency: nil, locale: enAE)
                == .failure(.invalidCurrency))
        #expect(WalletAmount.resolve(text: "€4.20", currencyAmount: (0, "AED"), fallbackCurrency: nil, locale: enAE)
                == .success(.init(amount: dec("4.20"), currency: "EUR", source: .text)))
    }

    @Test("garbled text or nothing at all is refused")
    func refused() {
        #expect(WalletAmount.resolve(text: "free", currencyAmount: nil, fallbackCurrency: "AED") == .failure(.invalidAmount))
        #expect(WalletAmount.resolve(text: nil, currencyAmount: nil, fallbackCurrency: "AED") == .failure(.missingAmount))
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
        let (outcome, dialog) = await intake(api).handle(amountText: "€4.20", currencyAmount: nil, fallbackCurrency: nil,
                                                         merchant: "Café", card: "Wio", locale: enAE)
        #expect(outcome == .delivered(status: "created"))
        #expect(dialog == "Logged to Personal.")
        let item = try #require(api.walletCalls.first?.items.first)
        #expect(item.currency == "EUR")
        #expect(item.amount == dec("4.20"))
    }

    @Test("an older automation is logged, with a pointer to the Amount setting")
    func olderAutomationTip() async {
        let api = StubAPI(.succeed(status: "created"))
        let (_, dialog) = await intake(api).handle(amountText: nil, currencyAmount: (dec("5"), "AED"),
                                                   fallbackCurrency: nil, merchant: "Shop", card: "Wio")
        #expect(dialog.hasPrefix("Logged to Personal."))
        #expect(dialog.hasSuffix(WalletIntake.setCurrencyTip))
        #expect(!dialog.contains("Shop"))
    }

    @Test("no currency: refused before anything is queued, and the line says what to set")
    func noCurrency() async {
        let api = StubAPI(.succeed(status: "created"))
        let (outcome, dialog) = await intake(api).handle(amountText: "12.50", currencyAmount: nil, fallbackCurrency: nil,
                                                         merchant: "Shop", card: "Wio", locale: enAE)
        #expect(outcome == .refused(code: "invalid_currency", message: WalletCapture.Problem.invalidCurrency.userMessage))
        #expect(dialog.contains("Currency if missing"))
        #expect(api.walletCalls.isEmpty)
    }
}
