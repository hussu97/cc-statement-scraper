import * as Sentry from "@sentry/react";
import { SupabaseClient } from "@supabase/supabase-js";
import { supabaseIntegration } from "@supabase/sentry-js-integration";
import { scrubBreadcrumb, scrubEvent } from "./sentry-scrub";

const dsn = import.meta.env.VITE_SENTRY_DSN as string | undefined;
const supabaseUrl = (import.meta.env.VITE_SUPABASE_URL as string | undefined) ?? "";

export const sentryEnabled = Boolean(dsn);

/** Initialise Sentry once. A no-op without VITE_SENTRY_DSN. */
export function initSentry(router: unknown): void {
  if (!dsn) return;
  Sentry.init({
    dsn,
    environment: (import.meta.env.VITE_SENTRY_ENVIRONMENT as string | undefined) ?? import.meta.env.MODE,
    release: import.meta.env.VITE_SENTRY_RELEASE as string | undefined,
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
        errors: true,
        // Never attach insert/update bodies (SMS text, secrets, notes).
        sanitizeBody: () => undefined,
      }),
    ],
    beforeSend: (event) => scrubEvent(event),
    beforeSendTransaction: (event) => scrubEvent(event),
    beforeBreadcrumb: (crumb) => scrubBreadcrumb(crumb),
  });
}

/** Send a TanStack Query failure, skipping expected client errors. */
export function reportQueryError(error: unknown, scope: string): void {
  if (!dsn) return;
  const status = (error as { status?: number; code?: string } | null)?.status;
  const code = (error as { code?: string } | null)?.code;
  // 4xx-like PostgREST / RPC errors (auth, not found, validation) are expected.
  if (status && status >= 400 && status < 500) return;
  if (code && /^(42501|P0002|22023|PGRST)/.test(code)) return;
  Sentry.captureException(error, { tags: { scope } });
}

export function setSentryProfile(profileCode: string | null): void {
  if (!dsn) return;
  Sentry.setTag("profile_code", profileCode ?? undefined);
}

export function setSentryUser(userId: string | null): void {
  if (!dsn) return;
  Sentry.setUser(userId ? { id: userId } : null);
}

export { Sentry };
