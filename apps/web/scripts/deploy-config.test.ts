import { describe, expect, it } from "vitest";
import { appleAppSiteAssociation, supabaseCsp, supabaseOrigin } from "./deploy-config";

describe("supabaseOrigin", () => {
  it("keeps only a hosted https origin", () => {
    expect(supabaseOrigin("https://example-ref.supabase.co/")).toBe("https://example-ref.supabase.co");
    expect(supabaseOrigin("http://127.0.0.1:54321")).toBeNull();
    expect(supabaseOrigin("not a url")).toBeNull();
    expect(supabaseOrigin(undefined)).toBeNull();
  });
});

describe("supabaseCsp", () => {
  it("pins connect-src and img-src to the one host, https and wss", () => {
    const csp = supabaseCsp("https://example-ref.supabase.co");
    const directives = new Map(csp.split("; ").map((d) => [d.split(" ")[0], d.split(" ").slice(1)]));
    expect(directives.get("connect-src")).toEqual([
      "'self'",
      "https://example-ref.supabase.co",
      "wss://example-ref.supabase.co",
      "https://*.ingest.sentry.io",
      "https://*.ingest.us.sentry.io",
      "https://*.ingest.de.sentry.io",
    ]);
    expect(directives.get("img-src")).toEqual(["'self'", "data:", "blob:", "https://example-ref.supabase.co"]);
    expect([...directives.keys()]).toEqual(["connect-src", "img-src"]);
  });
});

describe("appleAppSiteAssociation", () => {
  it("lists each TEAMID.bundle as a webcredentials app", () => {
    const json = appleAppSiteAssociation(" ABCDE12345.com.example.app , ABCDE12345.com.example.other ");
    expect(JSON.parse(json ?? "")).toEqual({ webcredentials: { apps: ["ABCDE12345.com.example.app", "ABCDE12345.com.example.other"] } });
  });

  it("emits nothing when unset", () => {
    expect(appleAppSiteAssociation(undefined)).toBeNull();
    expect(appleAppSiteAssociation(" ")).toBeNull();
  });

  it("refuses an id that isn't TEAMID.bundle", () => {
    expect(() => appleAppSiteAssociation("com.example.app")).toThrow(/TEAMID/);
  });
});
