// Client side of the 42a95f1 DB contract changes (resolve_review errors and
// not_a_transaction, recon 'n/a', merchant_search paging, statement_cycles
// 5000, documents.parse_warnings), and of 8834f76 (cards.wallet_name, Wallet
// rows in unknown_card reviews).
import { describe, expect, it } from "vitest";
import { NOT_A_TRANSACTION, reviewActionError, reviewFooterActions, unknownCardLabel, walletPassNameOf } from "@/data/reviews";
import { reconBadge, reconChecks, reconNote } from "@/lib/recon";
import { docWarnings, normalizeWalletName, STATEMENT_CYCLES_MAX, WALLET_NAME_MAX, walletNameError } from "@/data/cards";
import { MERCHANT_SEARCH_MAX, mergeSearchRows, merchantSearchArgs, merchantSearchPage, type MerchantRow, type MerchantSearchRow } from "@/data/rules";

describe("resolve_review: not a card transaction", () => {
  it("sends exactly {not_a_transaction: true} (dismiss would win server-side)", () => {
    expect(NOT_A_TRANSACTION).toStrictEqual({ not_a_transaction: true });
    expect(JSON.stringify(NOT_A_TRANSACTION)).toBe('{"not_a_transaction":true}');
  });

  it("is offered for SMS subjects only", () => {
    expect(reviewFooterActions({ reason: "unknown_card", subject_type: "sms" }, false)).toContain("not_a_transaction");
    expect(reviewFooterActions({ reason: "ambiguous", subject_type: "statement_line" }, false)).not.toContain("not_a_transaction");
    expect(reviewFooterActions({ reason: "orphaned", subject_type: "transaction" }, false)).not.toContain("not_a_transaction");
  });
});

describe("resolve_review / retry_sms_fallback errors", () => {
  it("P0002: already answered, or a code from another ledger", () => {
    expect(reviewActionError({ code: "P0002", message: "review rev_1 is not open" })).toMatch(/already answered/);
    expect(reviewActionError({ code: "P0002", message: "unknown transaction txn_x" })).toMatch(/no longer exists in this ledger/);
  });

  it("22023: account mismatch and other misfits", () => {
    expect(reviewActionError({ code: "22023", message: "transaction txn_x is on a different account" })).toMatch(/different card account/);
    expect(reviewActionError({ code: "22023", message: "transaction txn_x is not on this message's account" })).toMatch(/different card account/);
    expect(reviewActionError({ code: "22023", message: "sms sms_1 is already part of a transaction" })).toMatch(/already part of a transaction/);
    expect(reviewActionError({ code: "22023", message: "review rev_1 is not an open unparsed_sms review" })).toMatch(/sent to the AI again/);
    expect(reviewActionError({ code: "22023", message: "unsupported action" })).toMatch(/doesn't fit this review/);
  });

  it("passes other messages through", () => {
    expect(reviewActionError({ code: "42501", message: "You don't have permission to do that in this ledger." })).toBe("You don't have permission to do that in this ledger.");
    expect(reviewActionError(null)).toBe("Something went wrong.");
  });
});

describe("reconciliation status → label and tone", () => {
  it("renders 'n/a' (history extracts) neutrally, never as an error", () => {
    expect(reconBadge("n/a")).toEqual({ label: "Nothing to reconcile", tone: "neutral" });
    expect(reconNote("n/a")).toMatch(/History exports have no statement totals/);
  });

  it("maps the other statuses", () => {
    expect(reconBadge("ok")).toEqual({ label: "Reconciled", tone: "positive" });
    expect(reconBadge("warn")).toEqual({ label: "Check", tone: "warn" });
    expect(reconBadge("fail")).toEqual({ label: "Doesn't add up", tone: "danger" });
    expect(reconBadge(null)).toEqual({ label: "Not checked", tone: "neutral" });
    expect(reconBadge("someday")).toEqual({ label: "someday", tone: "neutral" });
    expect(reconNote("ok")).toBeNull();
  });

  it("explains unpriced lines and empty statements", () => {
    const rows = reconChecks({ unpriced_lines: 2, no_lines: true, superseded_lines: 4 });
    expect(rows.map((r) => [r.key, r.ok])).toEqual([
      ["unpriced", null],
      ["no_lines", false],
    ]);
    expect(rows[1]!.label).toMatch(/replaced by a newer parse/);
    expect(reconChecks({ no_lines: true, superseded_lines: 0 })[0]!.label).toMatch(/No lines were read/);
  });
});

describe("statements list", () => {
  it("asks statement_cycles for up to 5000 rows", () => {
    expect(STATEMENT_CYCLES_MAX).toBe(5000);
  });
});

describe("documents.parse_warnings", () => {
  it("lists strings and object messages, skipping junk", () => {
    expect(docWarnings(["Detected due date 2025-08-26", { message: "No ADCB rows matched expected patterns" }, { code: "skipped" }, 42, null, " "])).toEqual([
      "Detected due date 2025-08-26",
      "No ADCB rows matched expected patterns",
      "skipped",
    ]);
    expect(docWarnings(null)).toEqual([]);
    expect(docWarnings({ not: "an array" })).toEqual([]);
  });

  it("masks long digit runs (card / account numbers) and caps the length", () => {
    expect(docWarnings(["card 4111 1111 1111 1234 not registered"])).toEqual(["card •••• not registered"]);
    expect(docWarnings(["account 0123456789 skipped"])).toEqual(["account •••• skipped"]);
    expect(docWarnings(["total 1234.50 differs"])).toEqual(["total 1234.50 differs"]);
    expect(docWarnings(["x".repeat(400)])[0]).toHaveLength(160);
  });
});

describe("merchant_search paging", () => {
  it("asks for one row more than a page, capped at 2000", () => {
    expect(merchantSearchArgs(1, 100)).toEqual({ p_offset: 0, p_limit: 101 });
    expect(merchantSearchArgs(3, 200)).toEqual({ p_offset: 400, p_limit: 201 });
    expect(merchantSearchArgs(2, 2000)).toEqual({ p_offset: 2000, p_limit: MERCHANT_SEARCH_MAX });
  });

  it("trims the look-ahead row and reports a next page", () => {
    const rows = Array.from({ length: 101 }, (_, i) => i);
    expect(merchantSearchPage(rows, 100)).toEqual({ rows: rows.slice(0, 100), hasMore: true });
    expect(merchantSearchPage(rows.slice(0, 40), 100)).toEqual({ rows: rows.slice(0, 40), hasMore: false });
    expect(merchantSearchPage(Array.from({ length: 2000 }, (_, i) => i), 2000).hasMore).toBe(true);
  });

  it("keeps a known merchant's spend, category and suggestion; fills the rest from the hit", () => {
    const hit = (code: string, name: string, manual: string | null = null): MerchantSearchRow => ({
      merchant_code: code,
      display_name: name,
      merchant_key: name.toUpperCase(),
      txn_count: 7,
      last_date: "2026-09-30",
      manual_category_code: manual as string,
    });
    const known: MerchantRow = {
      merchant_code: "mer_a",
      merchant_name: "Carrefour",
      category_code: "cat_groc",
      category_name: "Groceries",
      amount: 1200,
      txn_count: 3,
      last_date: "2026-09-01",
      assignment: null,
    };
    const rows = mergeSearchRows([hit("mer_a", "CARREFOUR"), hit("mer_b", "Old Shop", "cat_x")], [known]);
    expect(rows[0]).toMatchObject({ merchant_name: "Carrefour", amount: 1200, category_code: "cat_groc", txn_count: 7, last_date: "2026-09-30" });
    expect(rows[1]).toMatchObject({ merchant_name: "Old Shop", amount: null, category_code: "cat_x", assignment: null });
  });
});

describe("cards.wallet_name", () => {
  it("normalises to what the CHECK accepts: trimmed, single spaces, 1-64 chars, empty is null", () => {
    expect(normalizeWalletName("  Wio   Credit\tCard ")).toBe("Wio Credit Card");
    expect(normalizeWalletName("")).toBeNull();
    expect(normalizeWalletName("   \n ")).toBeNull();
    expect(normalizeWalletName(null)).toBeNull();
    expect(normalizeWalletName(undefined)).toBeNull();
    expect(WALLET_NAME_MAX).toBe(64);
    expect(normalizeWalletName("x".repeat(80))).toHaveLength(64);
    // Cut at 64 then trimmed again, so a space at the cut never survives.
    expect(normalizeWalletName(`${"x".repeat(63)} yz`)).toBe("x".repeat(63));
  });

  it("23505 (unique per ledger, ignoring case) reads as a clash with another card", () => {
    expect(walletNameError({ code: "23505", message: 'duplicate key value violates unique constraint "cards_wallet_name_uq"' })).toBe(
      "Another card already uses this Wallet name.",
    );
    expect(walletNameError({ code: "23514", message: "check" })).toMatch(/1 to 64 characters/);
    expect(walletNameError({ code: "42501", message: "You don't have permission to do that in this ledger." })).toBe("You don't have permission to do that in this ledger.");
    expect(walletNameError(null)).toBe("Something went wrong.");
  });
});

describe("unknown_card reviews for Wallet payments", () => {
  const review = (candidates: unknown, reason = "unknown_card", subject_type = "sms") =>
    ({ reason, subject_type, candidates }) as Parameters<typeof walletPassNameOf>[0];

  it("reads the pass name from the candidates", () => {
    expect(walletPassNameOf(review([{ wallet_name: "Wio Credit" }]))).toBe("Wio Credit");
  });

  it("falls back to the loaded SMS row when it is a Wallet row", () => {
    expect(walletPassNameOf(review([]), { source: "wallet", wallet_pass_name: " Travel " })).toBe("Travel");
    expect(walletPassNameOf(review(null), { source: "wallet", wallet_pass_name: null })).toBe("");
  });

  it("is null for bank SMS and other reasons, so the register-card action stays", () => {
    expect(walletPassNameOf(review([{ bank_code: "FAB", last4: "1234" }]), { source: "sms", wallet_pass_name: null })).toBeNull();
    expect(walletPassNameOf(review([{ bank_code: "FAB", last4: "1234" }]))).toBeNull();
    expect(walletPassNameOf(review([{ wallet_name: "Wio" }], "ambiguous"))).toBeNull();
    expect(walletPassNameOf(review([{ wallet_name: "Wio" }], "unknown_card", "statement_line"))).toBeNull();
  });

  it("keeps dismiss and not-a-card-transaction (the card action is refused server-side)", () => {
    expect(reviewFooterActions({ reason: "unknown_card", subject_type: "sms" }, false)).toEqual(["not_a_transaction", "dismiss"]);
  });
});

describe("unknown_card reviews for a card named by its first six digits", () => {
  it("names the card by last4, else by its BIN, else unknown", () => {
    expect(unknownCardLabel("EIB", "4557", null)).toBe("EIB •4557");
    expect(unknownCardLabel("EIB", null, "542459")).toBe("EIB card starting 542459");
    expect(unknownCardLabel("EIB", "4557", "457828")).toBe("EIB •4557");
    expect(unknownCardLabel("FAB", undefined)).toBe("FAB •????");
    expect(unknownCardLabel(null, null, null)).toBe("•????");
  });
});
