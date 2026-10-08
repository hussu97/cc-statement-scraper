import { describe, expect, it } from "vitest";
import { applyActivityFilters, evidenceBadge, groupByDay, sortEvidence, type EvidenceItem, type FilterBuilder } from "./transactions";
import { domainsFor } from "./realtime";
import { chooseActiveProfile, profileKeyFromName, type ProfileSummary } from "./profile";
import { candidatesOf, groupReviews, type Review } from "./reviews";
import { countByStatus, checkUploadFiles } from "./cards";
import { friendlyMessage } from "./api";
import { sortInsights } from "./overview";

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
  ilike(c: string, p: string) { return this.add(`ilike ${c} ${p}`); }
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
      "ilike description %cafe%",
    ]);
  });

  it("source=both requires both kinds of evidence", () => {
    expect(applyActivityFilters(new FakeBuilder(), { source: "both", category: "cat_1" }).calls).toEqual(["eq category_code cat_1", "eq has_sms true", "eq has_statement true"]);
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
  it("maps tables to cached domains", () => {
    expect(domainsFor(["insights"])).toEqual(["insights"]);
    const d = domainsFor(["transactions", "match_reviews"]);
    expect(d).toContain("overview");
    expect(d).toContain("reviews");
    expect(new Set(d).size).toBe(d.length);
    expect(domainsFor(["unknown"])).toEqual([]);
  });
});

describe("profiles", () => {
  const p = (code: string): ProfileSummary => ({ profile_code: code, key: code, name: code, base_currency: "AED", role: "owner" });
  it("restores the stored profile when still accessible", () => {
    expect(chooseActiveProfile([p("a"), p("b")], "b")?.profile_code).toBe("b");
    expect(chooseActiveProfile([p("a"), p("b")], "gone")?.profile_code).toBe("a");
    expect(chooseActiveProfile([], "a")).toBeNull();
  });
  it("derives a valid key from a name", () => {
    expect(profileKeyFromName("Alice's Cards")).toBe("alice-s-cards");
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
});

describe("cards & documents", () => {
  it("counts documents by status", () => {
    expect(countByStatus([{ parse_status: "parsed" }, { parse_status: "failed" }, { parse_status: "parsed" }])).toEqual({ queued: 0, parsing: 0, parsed: 2, failed: 1 });
  });
  it("prechecks uploads", () => {
    const f = (name: string, size: number, type = "application/pdf") => ({ name, size, type }) as File;
    const r = checkUploadFiles([f("a.pdf", 10), f("b.png", 10, "image/png"), f("c.pdf", 30 * 1024 * 1024), f("d.pdf", 0)]);
    expect(r.ok.map((x) => x.name)).toEqual(["a.pdf"]);
    expect(r.rejected.map((x) => x.reason)).toEqual(["Not a PDF", "Larger than 25 MB", "Empty file"]);
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
});
