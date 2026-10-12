import { afterEach, describe, expect, it, vi } from "vitest";

// The lazily loaded SDK chunk (WEB-11): what it passes to Sentry.init, and Replay after it.
const { init, addIntegration } = vi.hoisted(() => ({ init: vi.fn(), addIntegration: vi.fn() }));
vi.mock("@sentry/react", () => ({
  init,
  addIntegration,
  replayIntegration: (opts: unknown) => ({ name: "replay", opts }),
  tanstackRouterBrowserTracingIntegration: () => ({ name: "router" }),
  addBreadcrumb: vi.fn(),
  captureException: vi.fn(),
  captureReactException: vi.fn(),
  startInactiveSpan: vi.fn(),
  setTag: vi.fn(),
  setUser: vi.fn(),
  SEMANTIC_ATTRIBUTE_SENTRY_OP: "sentry.op",
  SEMANTIC_ATTRIBUTE_SENTRY_ORIGIN: "sentry.origin",
}));
vi.mock("@supabase/sentry-js-integration", () => ({ supabaseIntegration: () => ({ name: "supabase" }) }));

const DSN = "https://key@o1.ingest.sentry.io/1";

/** A deployed build: a DSN, a real environment and not the Vite dev server. */
function deployed(environment = "production") {
  vi.stubEnv("VITE_SENTRY_DSN", DSN);
  vi.stubEnv("VITE_SENTRY_ENVIRONMENT", environment);
  vi.stubEnv("DEV", false);
}

afterEach(async () => {
  // Let a test's background Replay import land before the mocks reset.
  await new Promise((r) => setTimeout(r, 10));
  vi.unstubAllEnvs();
  vi.resetModules();
  init.mockReset();
  addIntegration.mockReset();
});

describe("startSentry", () => {
  it("tags every event app=web for the shared ledger-apps project", async () => {
    deployed();
    const { startSentry } = await import("./sentry-client");
    const { SENTRY_APP_TAGS } = await import("./sentry");
    startSentry({});
    expect(init).toHaveBeenCalledTimes(1);
    expect(init.mock.calls[0]?.[0]?.initialScope).toEqual({ tags: { app: "web" } });
    expect(init.mock.calls[0]?.[0]?.environment).toBe("production");
    expect(SENTRY_APP_TAGS).toEqual({ app: "web" });
  });

  it.each(["", "local", "development", "test", " Local "])("never initialises for environment %j, even when loaded directly", async (env) => {
    deployed(env);
    const { startSentry } = await import("./sentry-client");
    startSentry({});
    expect(init).not.toHaveBeenCalled();
  });

  it("never initialises without a DSN or on the Vite dev server", async () => {
    deployed();
    vi.stubEnv("VITE_SENTRY_DSN", "");
    await (await import("./sentry-client")).startSentry({});
    vi.resetModules();
    deployed();
    vi.stubEnv("DEV", true);
    await (await import("./sentry-client")).startSentry({});
    expect(init).not.toHaveBeenCalled();
  });

  it("adds error-only, fully masked Replay after init, not in it", async () => {
    deployed();
    const { startSentry } = await import("./sentry-client");
    startSentry({});
    const opts = init.mock.calls[0]?.[0];
    expect(opts.integrations.map((i: { name: string }) => i.name)).toEqual(["router", "supabase"]);
    expect(opts.replaysSessionSampleRate).toBe(0);
    expect(opts.replaysOnErrorSampleRate).toBe(1);
    await vi.waitFor(() => expect(addIntegration).toHaveBeenCalledTimes(1));
    expect(addIntegration.mock.calls[0]?.[0]).toEqual({ name: "replay", opts: { maskAllText: true, blockAllMedia: true } });
  });

  it("scrubs streamed spans via beforeSendSpan and leaves the supabase integration's duplicate error capture off", async () => {
    deployed();
    const { startSentry } = await import("./sentry-client");
    startSentry({});
    const opts = init.mock.calls[0]?.[0];
    // beforeSendTransaction is ignored under v11's default traceLifecycle "stream".
    expect(opts.traceLifecycle ?? "stream").toBe("stream");
    expect(opts.beforeSendTransaction).toBeUndefined();
    expect(typeof opts.beforeSendSpan).toBe("function");
    const span = opts.beforeSendSpan({
      name: "GET http://127.0.0.1:54321/rest/v1/v_transactions?description=ilike.*cafe*",
      span_id: "1",
      trace_id: "2",
      start_timestamp: 0,
      status: "ok",
      is_segment: false,
      attributes: {
        "db.table": "v_transactions",
        "db.query": ["ilike(description, *cafe*)"],
        "db.body": { notes: "dinner with a@b.co" },
        "url.full": "http://127.0.0.1:5173/activity?q=cafe",
        "http.request.header.authorization": "Bearer abc",
      },
    });
    expect(span.name).toBe("GET http://127.0.0.1:54321/rest/v1/v_transactions?description=[Filtered]");
    expect(span.attributes).toEqual({
      "db.table": "v_transactions",
      "db.query": "[Filtered]",
      "db.body": "[Filtered]",
      "url.full": "http://127.0.0.1:5173/activity?q=[Filtered]",
      "http.request.header.authorization": "[Filtered]",
    });
  });

  it("collects no personal data (sendDefaultPii off)", async () => {
    deployed();
    const { startSentry } = await import("./sentry-client");
    startSentry({});
    const opts = init.mock.calls[0]?.[0];
    expect(opts.sendDefaultPii).toBeUndefined();
    expect(opts.dataCollection).toMatchObject({ userInfo: false, cookies: false, httpHeaders: false, httpBodies: [], urlQueryParams: false });
  });
});
