import { describe, expect, it } from "vitest";
import { isSafeTagValue, scrubBreadcrumb, scrubEvent, scrubString } from "./sentry-scrub";

describe("sentry scrubber", () => {
  it("removes tokens, JWTs, bearer headers and emails from strings", () => {
    expect(scrubString("token ccs_0123456789abcdef0123 failed")).toBe("token ccs_[Filtered] failed");
    expect(scrubString("Bearer abc.def.ghi")).toBe("Bearer [Filtered]");
    expect(scrubString("jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.c2lnbmF0dXJlMTIz")).toBe("jwt [jwt]");
    expect(scrubString("user demo@ledger.local not found")).toBe("user [email] not found");
    expect(scrubString("/cb#access_token=secret&x=1")).toBe("/cb#access_token=[Filtered]&x=1");
  });

  it("strips headers, bodies, cookies and user PII from events", () => {
    const out = scrubEvent({
      request: {
        url: "https://x.test/rest?apikey=k",
        headers: { Authorization: "Bearer t", "X-Profile-Key": "demo", Accept: "json" },
        data: { body: "Your Cr.Card XXX4821 was used for AED 50" },
        cookies: { sb: "x" },
      },
      user: { id: "u1", email: "a@b.co", ip_address: "1.2.3.4" },
      extra: { p_value: "pdf-password", nested: { sms_body: "secret", txn_code: "txn_x" } },
      message: "failed for a@b.co",
    });
    expect(out.request?.headers).toEqual({ Authorization: "[Filtered]", "X-Profile-Key": "[Filtered]", Accept: "json" });
    expect(out.request?.data).toBeUndefined();
    expect(out.request?.cookies).toBeUndefined();
    expect(out.request?.url).toBe("https://x.test/rest?apikey=[Filtered]");
    expect(out.user).toEqual({ id: "u1" });
    expect(out.extra).toEqual({ p_value: "[Filtered]", nested: { sms_body: "[Filtered]", txn_code: "txn_x" } });
    expect(out.message).toBe("failed for [email]");
  });

  it("drops supabase breadcrumb bodies", () => {
    const b = scrubBreadcrumb({ category: "supabase", message: "insert", data: { table: "sms_messages", body: { body: "SMS text" }, token: "x" } });
    expect(b.data).toEqual({ table: "sms_messages", token: "[Filtered]" });
  });

  it("allows only opaque codes as tag values", () => {
    expect(isSafeTagValue("prf_01hzzzzzzzzzzzzzzzzzzzzzzz")).toBe(true);
    expect(isSafeTagValue("statements-upload")).toBe(true);
    expect(isSafeTagValue("me@x.com")).toBe(false);
    expect(isSafeTagValue("Your card was used for AED 50")).toBe(false);
  });
});

describe("span scrubber", () => {
  it("filters query values, bodies and secrets in span names, attributes and links", async () => {
    const { scrubSpan, stripQueryValues } = await import("./sentry-scrub");
    expect(stripQueryValues("/activity?q=cafe&page=2#x")).toBe("/activity?q=[Filtered]&page=[Filtered]#x");
    const out = scrubSpan({
      name: "from(sms_messages) for demo@ledger.local",
      attributes: {
        "db.table": "sms_messages",
        "db.query": ["eq(sms_code, sms_x)"],
        "db.body": { body: "Your card was used" },
        "sentry.op": "db.select",
        "http.url": { value: "https://x.test/rest/v1/t?apikey=k&select=*", type: "string" },
        count: 3,
      },
      links: [{ attributes: { "url.query": "q=cafe" } }],
    });
    expect(out.name).toBe("from(sms_messages) for [email]");
    expect(out.attributes).toEqual({
      "db.table": "sms_messages",
      "db.query": "[Filtered]",
      "db.body": "[Filtered]",
      "sentry.op": "db.select",
      "http.url": { value: "https://x.test/rest/v1/t?apikey=[Filtered]&select=[Filtered]", type: "string" },
      count: 3,
    });
    expect(out.links).toEqual([{ attributes: { "url.query": "[Filtered]" } }]);
  });
});
