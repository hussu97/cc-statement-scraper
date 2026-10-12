import { FunctionsFetchError, FunctionsHttpError, FunctionsRelayError } from "@supabase/supabase-js";
import { describe, expect, it } from "vitest";
import { ApiError, functionError, functionErrorFromBody, NETWORK_ERROR_MESSAGE } from "./api";

describe("Edge Function errors", () => {
  it("reads the {error: {code, message}} body", () => {
    const e = functionErrorFromBody({ error: { code: "INVITE_COOLDOWN", message: "an invite was sent recently" } }, 429, "fallback");
    expect(e).toBeInstanceOf(ApiError);
    expect(e.code).toBe("INVITE_COOLDOWN");
    expect(e.status).toBe(429);
    expect(e.message).toBe("an invite was sent recently");
  });

  it("falls back when the body is not the expected shape", () => {
    for (const body of [null, "text", {}, { error: "x" }, { error: { code: 5, message: "" } }]) {
      const e = functionErrorFromBody(body, 500, "Edge Function returned a non-2xx status code");
      expect(e.code).toBeUndefined();
      expect(e.message).toBe("Edge Function returned a non-2xx status code");
    }
  });

  it("unwraps a FunctionsHttpError response", async () => {
    const res = new Response(JSON.stringify({ error: { code: "ALREADY_ACTIVE", message: "already active" } }), { status: 409 });
    const e = await functionError(new FunctionsHttpError(res));
    expect(e.code).toBe("ALREADY_ACTIVE");
    expect(e.status).toBe(409);
    expect(e.message).toBe("already active");
  });

  it("keeps the generic message for a non-JSON error response", async () => {
    const e = await functionError(new FunctionsHttpError(new Response("<html>bad gateway</html>", { status: 502 })));
    expect(e.status).toBe(502);
    expect(e.code).toBeUndefined();
    expect(e.message).toMatch(/non-2xx/);
  });

  it("explains network and relay failures", async () => {
    expect((await functionError(new FunctionsFetchError(new TypeError("Failed to fetch")))).message).toBe(NETWORK_ERROR_MESSAGE);
    expect((await functionError(new FunctionsRelayError({}))).code).toBe("NETWORK");
    expect((await functionError(new Error("boom"))).message).toBe("boom");
  });
});
