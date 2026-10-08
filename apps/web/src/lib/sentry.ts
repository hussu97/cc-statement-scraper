import * as Sentry from "@sentry/react";
import { SupabaseClient } from "@supabase/supabase-js";
import { supabaseIntegration } from "@supabase/sentry-js-integration";
import { scrubBreadcrumb, scrubEvent, scrubSpan } from "./sentry-scrub";

const dsn = import.meta.env.VITE_SENTRY_DSN as string | undefined;
const environment = ((import.meta.env.VITE_SENTRY_ENVIRONMENT as string | undefined) ?? "").trim();
const supabaseUrl = (import.meta.env.VITE_SUPABASE_URL as string | undefined) ?? "";

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

/** Initialise Sentry once. A no-op without a DSN, in local environments and on the dev server. */
export function initSentry(router: unknown): void {
  if (!sentryEnabled) return;
  Sentry.init({
    dsn,
    environment,
    release: import.meta.env.VITE_SENTRY_RELEASE as string | undefined,
    initialScope: { tags: { ...SENTRY_APP_TAGS } },
    // Equivalent of sendDefaultPii=false in SDK v11: collect no user info,
    // cookies, headers, bodies, query params or DB payloads.
    dataCollection: {
      userInfo: false,
      cookies: false,
      httpHeaders: false,
      httpBodies: [],
      urlQueryParams: false,
      databaseQueryData: false,
      queues: false,
    },
    tracesSampleRate: 0.2,
    // Error-only replay, fully masked.
    replaysSessionSampleRate: 0,
    replaysOnErrorSampleRate: 1.0,
    tracePropagationTargets: supabaseUrl ? [supabaseUrl] : [],
    integrations: [
      Sentry.tanstackRouterBrowserTracingIntegration(router, {
        // supabase-js calls get their own spans from the Supabase integration.
        shouldCreateSpanForRequest: (url: string) => !(supabaseUrl && url.startsWith(`${supabaseUrl}/rest/`)),
      }),
      Sentry.replayIntegration({ maskAllText: true, blockAllMedia: true }),
      supabaseIntegration(SupabaseClient, Sentry, {
        tracing: true,
        breadcrumbs: true,
        // PostgREST errors reach Sentry once, through reportQueryError (query
        // and mutation caches), which skips expected 4xx/PGRST/42501 codes.
        // `errors: true` reported every failed request a second time, unfiltered.
        errors: false,
        // Never attach insert/update bodies (SMS text, secrets, notes).
        sanitizeBody: () => undefined,
      }),
    ],
    beforeSend: (event) => scrubEvent(event),
    // v11 streams spans by default, which skips beforeSendTransaction: scrub each span.
    beforeSendSpan: (span) => scrubSpan(span),
    beforeBreadcrumb: (crumb) => scrubBreadcrumb(crumb),
  });
}

/** Send a TanStack Query failure, skipping expected client errors. */
export function reportQueryError(error: unknown, scope: string): void {
  if (!sentryEnabled) return;
  const status = (error as { status?: number; code?: string } | null)?.status;
  const code = (error as { code?: string } | null)?.code;
  // 4xx-like PostgREST / RPC errors (auth, not found, validation) are expected.
  if (status && status >= 400 && status < 500) return;
  if (code && /^(42501|P0002|22023|PGRST)/.test(code)) return;
  Sentry.captureException(error, { tags: { scope } });
}

export function setSentryProfile(profileCode: string | null): void {
  if (!sentryEnabled) return;
  Sentry.setTag("profile_code", profileCode ?? undefined);
}

export function setSentryUser(userId: string | null): void {
  if (!sentryEnabled) return;
  Sentry.setUser(userId ? { id: userId } : null);
}

export { Sentry };
