import { afterEach, describe, expect, it, vi } from "vitest";

const { init } = vi.hoisted(() => ({ init: vi.fn() }));
vi.mock("@sentry/react", () => ({
  init,
  tanstackRouterBrowserTracingIntegration: () => ({ name: "router" }),
  replayIntegration: () => ({ name: "replay" }),
  captureException: vi.fn(),
  setTag: vi.fn(),
  setUser: vi.fn(),
}));
vi.mock("@supabase/sentry-js-integration", () => ({ supabaseIntegration: () => ({ name: "supabase" }) }));

afterEach(() => {
  vi.unstubAllEnvs();
  vi.resetModules();
  init.mockReset();
});

describe("initSentry", () => {
  it("tags every event app=web for the shared ledger-apps project", async () => {
    vi.stubEnv("VITE_SENTRY_DSN", "https://key@o1.ingest.sentry.io/1");
    const { initSentry, SENTRY_APP_TAGS } = await import("./sentry");
    initSentry({});
    expect(init).toHaveBeenCalledTimes(1);
    expect(init.mock.calls[0]?.[0]?.initialScope).toEqual({ tags: { app: "web" } });
    expect(SENTRY_APP_TAGS).toEqual({ app: "web" });
  });

  it("is a no-op without a DSN", async () => {
    vi.stubEnv("VITE_SENTRY_DSN", "");
    const { initSentry } = await import("./sentry");
    initSentry({});
    expect(init).not.toHaveBeenCalled();
  });
});
