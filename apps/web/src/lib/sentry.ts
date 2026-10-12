// Sentry's front door, and the only part of it in the first-load bundle (WEB-11). The SDK
// itself (`sentry-client.ts`) is loaded after first paint, and only for a deployed build;
// Replay comes later still (`sentry-replay.ts`). Locally nothing under `@sentry/` is fetched.
// Never import `@sentry/*` statically anywhere else: ESLint `no-restricted-imports` enforces it.

const dsn = import.meta.env.VITE_SENTRY_DSN as string | undefined;
const environment = ((import.meta.env.VITE_SENTRY_ENVIRONMENT as string | undefined) ?? "").trim();

/** Environments that never report, even with a DSN in .env.local. */
export const LOCAL_SENTRY_ENVIRONMENTS: readonly string[] = ["", "local", "development", "test"];

/**
 * Sentry runs only for a deployed build: a DSN, a non-local VITE_SENTRY_ENVIRONMENT
 * (e.g. "production", "preview") and not the Vite dev server. Pure, so it is unit-tested.
 */
export function shouldInitSentry(opts: { dsn: string | undefined; environment: string | undefined; dev: boolean }): boolean {
  if (!opts.dsn || opts.dev) return false;
  return !LOCAL_SENTRY_ENVIRONMENTS.includes((opts.environment ?? "").trim().toLowerCase());
}

export const sentryEnabled = shouldInitSentry({ dsn, environment, dev: Boolean(import.meta.env.DEV) });

/** Scope tags on every event: `ledger-apps` is shared with iOS (app=ios). */
export const SENTRY_APP_TAGS = { app: "web" } as const;

type SentryClient = typeof import("./sentry-client");

/** Resolves to the started SDK once it has loaded; null until initSentry runs (and always when disabled). */
let ready: Promise<SentryClient> | null = null;

/** Uncaught errors from before the SDK loaded, sent once it has. Capped: a render loop must not grow it. */
const EARLY_ERRORS_MAX = 10;
const early: unknown[] = [];

/** Run `fn` once the page has loaded and the browser is idle (or after `timeout` ms of not being idle). */
export function afterFirstPaint(fn: () => void, timeout = 3000): void {
  const idle = () =>
    typeof window.requestIdleCallback === "function" ? window.requestIdleCallback(() => fn(), { timeout }) : window.setTimeout(fn, 0);
  if (document.readyState === "complete") idle();
  else window.addEventListener("load", idle, { once: true });
}

function rememberEarly(error: unknown): void {
  if (early.length < EARLY_ERRORS_MAX) early.push(error);
}
const onEarlyError = (e: ErrorEvent) => rememberEarly(e.error ?? e.message);
const onEarlyRejection = (e: PromiseRejectionEvent) => rememberEarly(e.reason);

/**
 * Start Sentry after first paint. A no-op without a DSN, in local environments and on the dev
 * server: then the SDK is never even downloaded. Uncaught errors in the meantime are kept and
 * sent once it starts (the SDK's own global handlers take over from there).
 */
export function initSentry(router: unknown): void {
  if (!sentryEnabled || ready) return;
  window.addEventListener("error", onEarlyError);
  window.addEventListener("unhandledrejection", onEarlyRejection);
  ready = new Promise<SentryClient>((resolve, reject) => {
    afterFirstPaint(() => {
      import("./sentry-client")
        .then((client) => {
          window.removeEventListener("error", onEarlyError);
          window.removeEventListener("unhandledrejection", onEarlyRejection);
          client.startSentry(router);
          resolve(client);
          // After the user and profile tags queued on `ready` have been applied.
          window.setTimeout(() => {
            for (const error of early.splice(0)) client.captureException(error, { mechanism: { type: "onerror", handled: false } });
          }, 0);
        })
        .catch(reject);
    });
  });
  // A failed chunk load (offline, a deploy replaced the chunk) must not become an unhandled rejection.
  ready.catch(() => {});
}

/** Run `fn` with the SDK once it has started. Nothing happens when Sentry is off. */
function withSentry(fn: (client: SentryClient) => void): void {
  void ready?.then(fn, () => {});
}

/** Send a TanStack Query failure, skipping expected client errors. */
export function reportQueryError(error: unknown, scope: string): void {
  if (!sentryEnabled) return;
  const status = (error as { status?: number; code?: string } | null)?.status;
  const code = (error as { code?: string } | null)?.code;
  // 4xx-like PostgREST / RPC errors (auth, not found, validation) are expected.
  if (status && status >= 400 && status < 500) return;
  if (code && /^(42501|P0002|22023|PGRST)/.test(code)) return;
  withSentry((s) => s.captureException(error, { tags: { scope } }));
}

/** Send an error a React error boundary caught, with its component stack. */
export function reportRenderError(error: unknown, componentStack: string | null | undefined): void {
  if (!sentryEnabled) return;
  withSentry((s) => s.captureReactException(error, { componentStack: componentStack ?? "" }));
}

export function setSentryProfile(profileCode: string | null): void {
  if (!sentryEnabled) return;
  withSentry((s) => s.setTag("profile_code", profileCode ?? undefined));
}

export function setSentryUser(userId: string | null): void {
  if (!sentryEnabled) return;
  withSentry((s) => s.setUser(userId ? { id: userId } : null));
}
