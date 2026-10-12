import Foundation
import Observation

/// Settings → "Card names for payment shortcut": the ledger's cards and the
/// name each one has on the phone, which "Log Card Payment" passes as Card.
/// Owners edit the names; viewers see them read-only (the view hides editing,
/// and RLS refuses the write anyway).
@MainActor
@Observable
public final class CardWalletNamesModel {
    public private(set) var state: LoadState<[LedgerCard]> = .idle
    /// The card being saved, while the request runs.
    public private(set) var saving: String?
    /// The last save's outcome, per card: an error sentence, or nil.
    public private(set) var errors: [String: String] = [:]
    public private(set) var saved: Set<String> = []

    private let api: any LedgerAPI
    private var profileCode: String?

    public init(api: any LedgerAPI) { self.api = api }

    /// Active cards first, then replaced and closed ones, each by bank and last 4.
    public var cards: [LedgerCard] {
        (state.value ?? []).sorted {
            ($0.status != "active" ? 1 : 0, $0.bankCode, $0.last4) < ($1.status != "active" ? 1 : 0, $1.bankCode, $1.last4)
        }
    }

    /// Claimed only once the cards loaded and there are none.
    public var isEmpty: Bool { state.value?.isEmpty == true }

    public func load(profileCode: String) async {
        if self.profileCode != profileCode {
            state = .idle
            errors = [:]
            saved = []
        }
        self.profileCode = profileCode
        state = state.startLoading()
        do {
            let rows = try await api.cards(profileCode: profileCode)
            guard self.profileCode == profileCode else { return }
            state = .loaded(rows)
        } catch {
            guard self.profileCode == profileCode else { return }
            state = state.fail(error)
        }
    }

    /// Saves `raw` as the card's name (empty clears it). Returns true when saved.
    @discardableResult
    public func save(_ card: LedgerCard, name raw: String) async -> Bool {
        if let problem = WalletName.validate(raw) {
            errors[card.cardCode] = problem
            return false
        }
        let name = WalletName.normalise(raw)
        guard name != card.walletName, saving == nil else { return name == card.walletName }
        saving = card.cardCode
        defer { saving = nil }
        do {
            try await api.updateCardWalletName(cardCode: card.cardCode, name: name)
            errors[card.cardCode] = nil
            saved.insert(card.cardCode)
            if let profileCode { await load(profileCode: profileCode) }
            return true
        } catch {
            errors[card.cardCode] = WalletName.errorMessage(error)
            saved.remove(card.cardCode)
            return false
        }
    }

    public static let hint = """
    Type each card's name exactly as Wallet shows it on the card; capitals don't matter. If a payment \
    arrives with a name no card has, Shortcuts shows the name it passed: set it here and that payment, \
    and any others waiting, are filed on the card.
    """
}

