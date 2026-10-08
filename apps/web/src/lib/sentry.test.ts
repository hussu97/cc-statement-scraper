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

const DSN = "https://key@o1.ingest.sentry.io/1";

/** A deployed build: a DSN, a real environment and not the Vite dev server. */
function deployed(environment = "production") {
  vi.stubEnv("VITE_SENTRY_DSN", DSN);
  vi.stubEnv("VITE_SENTRY_ENVIRONMENT", environment);
  vi.stubEnv("DEV", false);
}

afterEach(() => {
  vi.unstubAllEnvs();
  vi.resetModules();
  init.mockReset();
});

describe("initSentry", () => {
  it("tags every event app=web for the shared ledger-apps project", async () => {
    deployed();
    const { initSentry, SENTRY_APP_TAGS } = await import("./sentry");
    initSentry({});
    expect(init).toHaveBeenCalledTimes(1);
    expect(init.mock.calls[0]?.[0]?.initialScope).toEqual({ tags: { app: "web" } });
    expect(init.mock.calls[0]?.[0]?.environment).toBe("production");
    expect(SENTRY_APP_TAGS).toEqual({ app: "web" });
  });

  it("is a no-op without a DSN", async () => {
    deployed();
    vi.stubEnv("VITE_SENTRY_DSN", "");
    const { initSentry } = await import("./sentry");
    initSentry({});
    expect(init).not.toHaveBeenCalled();
  });

  it.each(["", "local", "development", "test", " Local "])("never initialises for environment %j, even with a DSN", async (env) => {
    deployed(env);
    const { initSentry, sentryEnabled } = await import("./sentry");
    initSentry({});
    expect(sentryEnabled).toBe(false);
    expect(init).not.toHaveBeenCalled();
  });

  it("never initialises on the Vite dev server, even with a production environment", async () => {
    deployed("production");
    vi.stubEnv("DEV", true);
    const { initSentry } = await import("./sentry");
    initSentry({});
    expect(init).not.toHaveBeenCalled();
  });

  it("scrubs streamed spans via beforeSendSpan and leaves the supabase integration's duplicate error capture off", async () => {
    deployed();
    const { initSentry } = await import("./sentry");
    initSentry({});
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
});

describe("shouldInitSentry", () => {
  it("needs a DSN, a deployed environment and a production build", async () => {
    const { shouldInitSentry } = await import("./sentry");
    expect(shouldInitSentry({ dsn: DSN, environment: "production", dev: false })).toBe(true);
    expect(shouldInitSentry({ dsn: DSN, environment: "preview", dev: false })).toBe(true);
    expect(shouldInitSentry({ dsn: DSN, environment: undefined, dev: false })).toBe(false);
    expect(shouldInitSentry({ dsn: DSN, environment: "development", dev: false })).toBe(false);
    expect(shouldInitSentry({ dsn: DSN, environment: "production", dev: true })).toBe(false);
    expect(shouldInitSentry({ dsn: undefined, environment: "production", dev: false })).toBe(false);
  });
});
