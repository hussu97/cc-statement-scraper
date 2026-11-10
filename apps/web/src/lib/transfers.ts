// Linked transfers (public.card_transfers via v_transactions): a card repayment, or a move between
// two of the ledger's own bank accounts (the peer then has no card, and `last4` is its account_ref),
// linked by the server. Pure display helpers; the pairing itself is never decided here (§2.2).

export interface TransferPeer {
  /** "Paid to" on the paying card's debit, "From" on the paid card's credit. */
  prefix: "Paid to" | "From";
  txnCode: string;
  bankCode: string | null;
  last4: string | null;
}

interface TransferFields {
  direction: string | null;
  transfer_txn_code: string | null;
  transfer_bank_code: string | null;
  transfer_card_last4: string | null;
}

/** The other side of a linked transfer, or null when the row is not one. */
export function transferPeer(t: TransferFields): TransferPeer | null {
  if (!t.transfer_txn_code) return null;
  return {
    prefix: t.direction === "debit" ? "Paid to" : "From",
    txnCode: t.transfer_txn_code,
    bankCode: t.transfer_bank_code,
    last4: t.transfer_card_last4,
  };
}
