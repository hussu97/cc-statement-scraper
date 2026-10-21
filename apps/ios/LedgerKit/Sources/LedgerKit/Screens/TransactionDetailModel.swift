import Foundation
import Observation

/// The transaction sheet's details beside the row (PAR-2, the web drawer): the
/// merchant context, the reversal pair and the evidence timeline. Everyone who
/// can see the ledger opens it; only owners get the edit controls with it.
///
/// An SMS's text is read when the reader opens it and dropped when they close
/// it or the sheet: it lives only in this model, never in a log or a cache.
@MainActor
@Observable
public final class TransactionDetailModel {
    public let transaction: LedgerTransaction
    /// Nil until loaded, and for a row without a merchant or with no visit.
    public private(set) var merchantLine: String?
    public private(set) var merchantFailed = false
    public private(set) var related: [LedgerTransaction] = []
    public private(set) var evidence: LoadState<[EvidenceItem]> = .idle
    /// The SMS whose text is open, by code, and what it holds.
    public private(set) var openSMS: [String: LoadState<String>] = [:]

    private let api: any LedgerAPI
    private let profileCode: String

    public init(transaction: LedgerTransaction, profileCode: String, api: any LedgerAPI) {
        self.transaction = transaction
        self.profileCode = profileCode
        self.api = api
    }

    /// Whether the sheet shows a merchant row at all.
    public var hasMerchant: Bool { transaction.merchantCode != nil }

    /// The evidence section's empty state, said only when the server returned none.
    public var noEvidenceMessage: String? {
        guard case .loaded(let items) = evidence, items.isEmpty else { return nil }
        return "No evidence is attached. This transaction is orphaned and will show in Review."
    }

    public func load() async {
        evidence = .loading(previous: evidence.value)
        async let context: Void = loadMerchant()
        async let pair: Void = loadRelated()
        do {
            evidence = .loaded(try await api.transactionEvidence(profileCode: profileCode, txnCode: transaction.txnCode))
        } catch {
            evidence = evidence.fail(error)
        }
        await context
        await pair
    }

    public func isOpen(_ smsCode: String) -> Bool { openSMS[smsCode] != nil }

    /// Shows or hides an SMS's text; showing reads it from the server each time.
    public func toggleSMS(_ smsCode: String) async {
        if openSMS[smsCode] != nil {
            openSMS[smsCode] = nil
            return
        }
        openSMS[smsCode] = .loading(previous: nil)
        do {
            let body = try await api.smsBody(profileCode: profileCode, smsCode: smsCode)
            guard openSMS[smsCode] != nil else { return }   // closed while loading
            openSMS[smsCode] = .loaded(body ?? "")
        } catch {
            guard openSMS[smsCode] != nil else { return }
            openSMS[smsCode] = .failed("Couldn't load the message.", previous: nil)
        }
    }

    /// The sheet of a related transaction (the reversal link), read-only.
    public func detail(for txn: LedgerTransaction) -> TransactionDetailModel {
        TransactionDetailModel(transaction: txn, profileCode: profileCode, api: api)
    }

    /// The owner's "Link to investment", saved through the screen that opened the sheet.
    public func linker(target: any TransactionEditing) -> TransactionLinkModel {
        TransactionLinkModel(transaction: transaction, profileCode: profileCode, api: api, target: target)
    }

    /// Hides every SMS text (the sheet closing).
    public func closeAllSMS() { openSMS = [:] }

    private func loadMerchant() async {
        guard let merchant = transaction.merchantCode else { return }
        do {
            merchantLine = try await api.merchantContext(profileCode: profileCode, merchantCode: merchant).line
            merchantFailed = false
        } catch {
            merchantFailed = true
        }
    }

    private func loadRelated() async {
        // A failure leaves the section out, as on the web: it only adds a link.
        related = (try? await api.relatedTransactions(profileCode: profileCode, txn: transaction)) ?? []
    }
}
