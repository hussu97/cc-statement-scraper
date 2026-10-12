// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";

// The front door (WEB-11): the SDK chunk loads only for a deployed build, and only after
// first paint; anything reported before then waits for it. The SDK chunk itself is mocked
// here; its init options are tested in sentry-client.test.ts.
const client = vi.hoisted(() => ({
  startSentry: vi.fn(),
  captureException: vi.fn(),
  captureReactException: vi.fn(),
  setTag: vi.fn(),
  setUser: vi.fn(),
}));
const loaded = vi.hoisted(() => ({ count: 0 }));
vi.mock("./sentry-client", () => {
  loaded.count += 1;
  return client;
});

const DSN = "https://key@o1.ingest.sentry.io/1";

/** A deployed build: a DSN, a real environment and not the Vite dev server. */
function deployed(environment = "production") {
  vi.stubEnv("VITE_SENTRY_DSN", DSN);
  vi.stubEnv("VITE_SENTRY_ENVIRONMENT", environment);
  vi.stubEnv("DEV", false);
}

/** Let the idle callback, the dynamic import and the queued calls run. */
const settle = () => new Promise((r) => setTimeout(r, 20));

afterEach(() => {
  vi.unstubAllEnvs();
  vi.resetModules();
  loaded.count = 0;
  for (const fn of Object.values(client)) fn.mockReset();
});

describe("initSentry", () => {
  it("starts the SDK after first paint, not during the first render", async () => {
    deployed();
    const { initSentry } = await import("./sentry");
    const router = { name: "router" };
    initSentry(router);
    expect(client.startSentry).not.toHaveBeenCalled();
    await settle();
    expect(client.startSentry).toHaveBeenCalledTimes(1);
    expect(client.startSentry).toHaveBeenCalledWith(router);
  });

  it("starts once, however often it is called", async () => {
    deployed();
    const { initSentry } = await import("./sentry");
    initSentry({});
    initSentry({});
    await settle();
    expect(client.startSentry).toHaveBeenCalledTimes(1);
  });

  it("is a no-op without a DSN: the SDK is never downloaded", async () => {
    deployed();
    vi.stubEnv("VITE_SENTRY_DSN", "");
    const { initSentry, reportQueryError, setSentryUser } = await import("./sentry");
    initSentry({});
    reportQueryError(new Error("boom"), "query:x");
    setSentryUser("u1");
    await settle();
    expect(loaded.count).toBe(0);
    expect(client.startSentry).not.toHaveBeenCalled();
  });

  it.each(["", "local", "development", "test", " Local "])("never loads the SDK for environment %j, even with a DSN", async (env) => {
    deployed(env);
    const { initSentry, sentryEnabled } = await import("./sentry");
    initSentry({});
    await settle();
    expect(sentryEnabled).toBe(false);
    expect(loaded.count).toBe(0);
  });

  it("never loads the SDK on the Vite dev server, even with a production environment", async () => {
    deployed("production");
    vi.stubEnv("DEV", true);
    const { initSentry } = await import("./sentry");
    initSentry({});
    await settle();
    expect(loaded.count).toBe(0);
  });

  it("applies the user and profile set before the SDK loaded, then reports query errors", async () => {
    deployed();
    const { initSentry, reportQueryError, setSentryProfile, setSentryUser } = await import("./sentry");
    initSentry({});
    setSentryUser("user-1");
    setSentryProfile("prf_01");
    const error = Object.assign(new Error("db down"), { status: 503 });
    reportQueryError(error, "query:cards");
    await settle();
    expect(client.setUser).toHaveBeenCalledWith({ id: "user-1" });
    expect(client.setTag).toHaveBeenCalledWith("profile_code", "prf_01");
    expect(client.captureException).toHaveBeenCalledWith(error, { tags: { scope: "query:cards" } });
    expect(client.startSentry.mock.invocationCallOrder[0]).toBeLessThan(client.setUser.mock.invocationCallOrder[0]!);
  });

  it("skips expected client errors", async () => {
    deployed();
    const { initSentry, reportQueryError } = await import("./sentry");
    initSentry({});
    reportQueryError(Object.assign(new Error("nope"), { status: 403 }), "query:x");
    reportQueryError(Object.assign(new Error("rls"), { code: "42501" }), "query:x");
    reportQueryError(Object.assign(new Error("range"), { code: "PGRST103" }), "query:x");
    await settle();
    expect(client.captureException).not.toHaveBeenCalled();
  });

  it("sends uncaught errors from before the SDK loaded, after the user is set", async () => {
    deployed();
    const { initSentry, setSentryUser } = await import("./sentry");
    initSentry({});
    setSentryUser("user-1");
    const early = new Error("early");
    window.dispatchEvent(new ErrorEvent("error", { error: early, message: "early" }));
    await settle();
    expect(client.captureException).toHaveBeenCalledWith(early, { mechanism: { type: "onerror", handled: false } });
    expect(client.setUser.mock.invocationCallOrder[0]).toBeLessThan(client.captureException.mock.invocationCallOrder[0]!);
  });

  it("reports what a React error boundary caught, with its component stack", async () => {
    deployed();
    const { initSentry, reportRenderError } = await import("./sentry");
    initSentry({});
    const error = new Error("render");
    reportRenderError(error, "\n    at Overview");
    await settle();
    expect(client.captureReactException).toHaveBeenCalledWith(error, { componentStack: "\n    at Overview" });
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
