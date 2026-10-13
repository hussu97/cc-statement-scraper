import { describe, expect, it, vi } from "vitest";
import { renderToString } from "react-dom/server";
import { QueryClient, QueryClientProvider, type UseMutationResult } from "@tanstack/react-query";

vi.mock("@/lib/supabase", () => ({
  supabase: { rpc: vi.fn(async () => ({ data: { token_code: "tok_x", token: "plaintext" }, error: null })) },
}));

const { useCreateServiceToken, useSetMailboxSecret, useSetProfileSecret, useRenameProfile } = await import("./settings");

type AnyMutation = UseMutationResult<unknown, Error, never>;

/** Mount the hook once, run one mutation, and return the cached mutation's options. */
async function cachedGcTime(useHook: () => unknown, variables: unknown): Promise<number | undefined> {
  const qc = new QueryClient();
  let m: AnyMutation | undefined;
  function Probe() {
    m = useHook() as AnyMutation;
    return null;
  }
  renderToString(
    <QueryClientProvider client={qc}>
      <Probe />
    </QueryClientProvider>,
  );
  await m!.mutateAsync(variables as never).catch(() => undefined);
  const [mutation] = qc.getMutationCache().getAll();
  return mutation?.options.gcTime;
}

describe("mutations that carry a secret leave the MutationCache at once (WEB-50)", () => {
  it("new service token plaintext", async () => {
    expect(await cachedGcTime(() => useCreateServiceToken("prf_x"), { name: "scraper", scopes: ["sms:ingest"] })).toBe(0);
  });

  it("PDF passwords (Vault)", async () => {
    expect(await cachedGcTime(() => useSetProfileSecret("prf_x"), { key: "FAB_PDF_PASSWORD", value: "pw" })).toBe(0);
  });

  it("mailbox refresh tokens", async () => {
    expect(await cachedGcTime(() => useSetMailboxSecret(), { mailboxCode: "mbx_x", value: "rt" })).toBe(0);
  });

  it("other mutations keep the default", async () => {
    expect(await cachedGcTime(() => useRenameProfile("prf_x"), "Home")).not.toBe(0);
  });
});
