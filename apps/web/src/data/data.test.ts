import { describe, expect, it } from "vitest";
import { activitySummaryArgs, applyActivityFilters, evidenceBadge, groupByDay, isNoteDirty, noteToSave, sortEvidence, type EvidenceItem, type FilterBuilder } from "./transactions";
import { channelTopic, invalidationKeys } from "./realtime";
import { keys, LEDGER_DOMAINS } from "./keys";
import { chooseActiveProfile, memberProfiles, profileKeyFromName, toProfileSummaries, type ProfileRow, type ProfileSummary } from "./profile";
import { attachContexts, candidatesOf, contextOf, groupReviews, type Review, type ReviewContextRow } from "./reviews";
import { checkUploadFiles } from "./cards";
import { friendlyMessage } from "./api";
import { pendingSummary, sortInsights } from "./overview";

class FakeBuilder implements FilterBuilder<FakeBuilder> {
  calls: string[] = [];
  private add(s: string) {
    this.calls.push(s);
    return this;
  }
  eq(c: string, v: unknown) { return this.add(`eq ${c} ${String(v)}`); }
  gte(c: string, v: unknown) { return this.add(`gte ${c} ${String(v)}`); }
  lte(c: string, v: unknown) { return this.add(`lte ${c} ${String(v)}`); }
  is(c: string, v: null | boolean) { return this.add(`is ${c} ${String(v)}`); }
  or(f: string) { return this.add(`or ${f}`); }
}

describe("activity query filters", () => {
  it("maps every filter to PostgREST calls", () => {
    const b = applyActivityFilters(new FakeBuilder(), {
      from: "2026-10-01", to: "2026-10-31", account: "acc_x", card: "crd_x", category: "none", status: "pending", source: "sms", q: "cafe",
    });
    expect(b.calls).toEqual([
      "gte txn_date 2026-10-01",
      "lte txn_date 2026-10-31",
      "eq account_code acc_x",
      "eq card_code crd_x",
      "is category_code null",
      "eq status pending",
      "eq has_sms true",
      "eq has_statement false",
      "or description.ilike.*cafe*,merchant_name.ilike.*cafe*",
    ]);
  });

  it("source=both requires both kinds of evidence", () => {
    expect(applyActivityFilters(new FakeBuilder(), { source: "both", category: "cat_1" }).calls).toEqual(["eq category_code cat_1", "eq has_sms true", "eq has_statement true"]);
  });

  it("a blank search adds no filter", () => {
    expect(applyActivityFilters(new FakeBuilder(), { q: "   " }).calls).toEqual([]);
  });
});

describe("activity summary args", () => {
  it("maps every filter and ignores paging and the drawer", () => {
    expect(
      activitySummaryArgs("prf_1", {
        from: "2026-10-01", to: "2026-10-31", account: "acc_x", card: "crd_x", category: "cat_1", status: "posted", source: "both", q: "cafe", page: 3, size: 200, txn: "txn_x",
      }),
    ).toEqual({
      p_profile_code: "prf_1", p_from: "2026-10-01", p_to: "2026-10-31", p_account_code: "acc_x", p_card_code: "crd_x", p_category_code: "cat_1", p_status: "posted", p_source: "both", p_q: "cafe",
    });
  });

  it("uncategorized becomes p_uncategorized, not a category code", () => {
    expect(activitySummaryArgs("prf_1", { category: "none" })).toEqual({ p_profile_code: "prf_1", p_uncategorized: true });
  });

  it("no filters is just the profile; a blank search is dropped", () => {
    expect(activitySummaryArgs("prf_1", {})).toEqual({ p_profile_code: "prf_1" });
    expect(activitySummaryArgs("prf_1", { q: "  " })).toEqual({ p_profile_code: "prf_1" });
  });
});

describe("transaction helpers", () => {
  it("groups consecutive rows by day", () => {
    const g = groupByDay([{ txn_date: "2026-10-06" }, { txn_date: "2026-10-06" }, { txn_date: "2026-10-05" }]);
    expect(g.map((x) => [x.day, x.rows.length])).toEqual([["2026-10-06", 2], ["2026-10-05", 1]]);
  });

  it("names the evidence badge", () => {
    expect(evidenceBadge({ has_sms: true, has_statement: true, status: "posted" })).toBe("both");
    expect(evidenceBadge({ has_sms: true, has_statement: false, status: "pending" })).toBe("sms");
    expect(evidenceBadge({ has_sms: false, has_statement: true, status: "posted" })).toBe("statement");
    expect(evidenceBadge({ has_sms: false, has_statement: false, status: "orphaned" })).toBe("orphaned");
  });

  it("orders evidence active-first then by time", () => {
    const e = (code: string, active: boolean, at: string, sms = true) =>
      ({
        evidence_code: code, is_active: active, created_at: at,
        sms_messages: sms ? { event_at: at, received_at: at } : null,
        statement_lines: sms ? null : { txn_date: at.slice(0, 10), posting_date: null },
      }) as unknown as EvidenceItem;
    const sorted = sortEvidence([e("c", false, "2026-01-01T00:00:00Z"), e("b", true, "2026-01-03T00:00:00Z", false), e("a", true, "2026-01-02T08:00:00Z")]);
    expect(sorted.map((x) => x.evidence_code)).toEqual(["a", "b", "c"]);
  });
});

describe("realtime invalidation", () => {
  it("maps tables to cached keys", () => {
    expect(invalidationKeys("P", ["insights"])).toEqual([["p", "P", "insights"]]);
    expect(invalidationKeys("P", ["unknown"])).toEqual([]);
    const both = invalidationKeys("P", ["transactions", "match_reviews"]);
    expect(both).toContainEqual(["p", "P", "overview"]);
    expect(both).toContainEqual(["p", "P", "reviews"]);
    // ["reviews"] already covers the open list; no duplicates either.
    expect(both).not.toContainEqual(keys.reviews("P"));
    expect(new Set(both.map((k) => k.join("/"))).size).toBe(both.length);
  });

  it("a transaction event refetches only the open-review list, not every review key (WEB-10r)", () => {
    const k = invalidationKeys("P", ["transactions"]);
    expect(k).toContainEqual(keys.reviews("P"));
    expect(k).not.toContainEqual(["p", "P", "reviews"]);
    expect(k).not.toContainEqual(keys.reviewCount("P"));
    for (const d of LEDGER_DOMAINS.filter((x) => x !== "reviews")) expect(k).toContainEqual(["p", "P", d]);
  });

  it("gives every subscription its own channel topic (WEB-09)", () => {
    expect(channelTopic("PRF_1", "n")).toBe("ledger:PRF_1:n");
    const a = channelTopic("PRF_1");
    const b = channelTopic("PRF_1");
    expect(a).toMatch(/^ledger:PRF_1:[0-9a-f-]{36}$/);
    expect(a).not.toBe(b);
  });
});

describe("profiles", () => {
  const p = (code: string): ProfileSummary => ({ profile_code: code, key: code, name: code, base_currency: "AED", role: "owner", isMember: true });
  it("restores the stored profile when still accessible", () => {
    expect(chooseActiveProfile([p("a"), p("b")], "b")?.profile_code).toBe("b");
    expect(chooseActiveProfile([p("a"), p("b")], "gone")?.profile_code).toBe("a");
    expect(chooseActiveProfile([], "a")).toBeNull();
  });
  it("falls back to a membership before a super-admin view", () => {
    const other = { ...p("a"), role: "viewer" as const, isMember: false };
    expect(chooseActiveProfile([other, p("b")], null)?.profile_code).toBe("b");
    expect(chooseActiveProfile([other], null)?.profile_code).toBe("a");
  });
  it("maps rows to summaries: own role, super-admin view, members first", () => {
    const row = (code: string, name: string, members: ProfileRow["profile_members"]): ProfileRow => ({ profile_code: code, key: code, name, base_currency: "AED", profile_members: members });
    const out = toProfileSummaries(
      [
        row("p1", "Zeta", [{ role: "viewer", user_id: "u1" }]),
        row("p2", "Alpha", []),
        row("p3", "Mid", [{ role: "owner", user_id: "u1" }]),
        row("p4", "Beta", null),
        row("p5", "Aaa", [{ role: "owner", user_id: "someone-else" }]),
      ],
      "u1",
    );
    expect(out.map((x) => [x.profile_code, x.role, x.isMember])).toEqual([
      ["p3", "owner", true],
      ["p1", "viewer", true],
      ["p5", "viewer", false],
      ["p2", "viewer", false],
      ["p4", "viewer", false],
    ]);
    expect(memberProfiles(out).map((x) => x.profile_code)).toEqual(["p3", "p1"]);
  });
  it("derives a valid key from a name", () => {
    expect(profileKeyFromName("Hussain's Cards")).toBe("hussain-s-cards");
    expect(profileKeyFromName("Ä")).toMatch(/^[a-z0-9_-]{2,40}$/);
    expect(profileKeyFromName("x".repeat(80))).toHaveLength(32);
  });
});

describe("reviews", () => {
  const r = (reason: string, code: string): Review => ({ reason, review_code: code, candidates: [] }) as unknown as Review;
  it("groups by reason in a stable order", () => {
    const g = groupReviews([r("orphaned", "1"), r("unknown_card", "2"), r("orphaned", "3"), r("zzz", "4")]);
    expect(g.map((x) => [x.reason, x.items.length])).toEqual([["unknown_card", 1], ["orphaned", 2], ["zzz", 1]]);
  });
  it("reads candidates defensively", () => {
    expect(candidatesOf({ candidates: [{ txn_code: "t", score: 80 }] } as unknown as Review)).toEqual([{ txn_code: "t", score: 80 }]);
    expect(candidatesOf({ candidates: {} } as unknown as Review)).toEqual([]);
  });
  it("pairs each review with its review_context row by code (WEB-10r)", () => {
    const ctx = (code: string, over: Partial<ReviewContextRow> = {}) =>
      ({ review_code: code, line: null, sms: null, txn: null, statement: null, candidates: [], template: null, ...over }) as unknown as ReviewContextRow;
    const out = attachContexts([r("ambiguous", "a"), r("orphaned", "b"), r("orphaned", "c")], [
      ctx("b", { txn: { txn_code: "t1" } }),
      ctx("a", { line: { line_code: "l1" }, candidates: [{ txn_code: "t2" }, { txn_code: "t3" }] }),
    ]);
    expect(out.map((x) => x.review_code)).toEqual(["a", "b", "c"]);
    expect(out[0]!.ctx.line).toEqual({ line_code: "l1" });
    expect(out[0]!.ctx.candidates.map((t) => t.txn_code)).toEqual(["t2", "t3"]);
    expect(out[1]!.ctx.txn).toEqual({ txn_code: "t1" });
    // A review the server returned no row for (resolved meanwhile) gets an empty context, not a crash.
    expect(out[2]!.ctx).toEqual({ line: null, sms: null, txn: null, statement: null, candidates: [], template: null });
  });
  it("reads review_context jsonb defensively", () => {
    expect(contextOf(undefined).candidates).toEqual([]);
    const odd = { review_code: "x", line: [], sms: "text", txn: null, statement: 1, candidates: {}, template: null } as unknown as ReviewContextRow;
    expect(contextOf(odd)).toEqual({ line: null, sms: null, txn: null, statement: null, candidates: [], template: null });
  });
});

describe("cards & documents", () => {
  it("prechecks uploads", () => {
    const f = (name: string, size: number, type = "application/pdf") => ({ name, size, type }) as File;
    const r = checkUploadFiles([f("a.pdf", 10), f("b.png", 10, "image/png"), f("c.pdf", 30 * 1024 * 1024), f("d.pdf", 0)]);
    expect(r.ok.map((x) => x.name)).toEqual(["a.pdf"]);
    expect(r.rejected.map((x) => x.reason)).toEqual(["Not a PDF", "Larger than 25 MB", "Empty file"]);
  });
  it("sends at most 20 files per upload, like the Edge Function (WEB-48)", () => {
    const files = Array.from({ length: 22 }, (_, i) => ({ name: `s${i}.pdf`, size: 10, type: "application/pdf" }) as File);
    const r = checkUploadFiles(files);
    expect(r.ok).toHaveLength(20);
    expect(r.rejected.map((x) => x.name)).toEqual(["s20.pdf", "s21.pdf"]);
    expect(r.rejected[0]!.reason).toMatch(/Over 20 files/);
  });
});

describe("api + insights", () => {
  it("maps permission errors to plain sentences", () => {
    expect(friendlyMessage({ code: "42501", message: "not a owner of profile prf_x" })).toBe("You don't have permission to do that in this ledger.");
    expect(friendlyMessage({ message: "boom" })).toBe("boom");
  });
  it("sorts insights by severity then recency", () => {
    const i = (severity: string, created_at: string) => ({ severity, created_at });
    expect(sortInsights([i("info", "2026-10-02"), i("alert", "2026-10-01"), i("info", "2026-10-03")]).map((x) => x.created_at)).toEqual(["2026-10-01", "2026-10-03", "2026-10-02"]);
  });
  it("saves a note trimmed, and a blank one as null", () => {
    expect(noteToSave("  coffee with Sam \n")).toBe("coffee with Sam");
    expect(noteToSave("   ")).toBeNull();
  });
  it("compares the note as it would be saved, so padding doesn't leave it dirty (WEB-49)", () => {
    expect(isNoteDirty("  coffee  ", "coffee")).toBe(false);
    expect(isNoteDirty("  ", null)).toBe(false);
    expect(isNoteDirty("", undefined)).toBe(false);
    expect(isNoteDirty("coffee!", "coffee")).toBe(true);
    expect(isNoteDirty("", "coffee")).toBe(true);
  });
  it("sums up pending SMS in one line from the server's count and amount (WEB-35)", () => {
    expect(pendingSummary(31, "3082.40")).toBe("31 pending · AED 3,082");
    expect(pendingSummary(1200, "15000.00")).toBe("1,200 pending · AED 15,000");
    expect(pendingSummary(0, "0")).toBeNull();
  });
});
