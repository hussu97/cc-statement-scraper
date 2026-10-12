// The Sentry SDK, loaded by `lib/sentry.ts` after first paint and only for a deployed build
// (WEB-11). Named imports only: a namespace import (`import * as Sentry`) keeps every export,
// Feedback and Replay included, in the chunk. Replay is a chunk of its own (`sentry-replay.ts`).
import {
  addBreadcrumb,
  captureException,
  captureReactException,
  init,
  SEMANTIC_ATTRIBUTE_SENTRY_OP,
  SEMANTIC_ATTRIBUTE_SENTRY_ORIGIN,
  setTag,
  setUser,
  startInactiveSpan,
  tanstackRouterBrowserTracingIntegration,
  type BrowserOptions,
} from "@sentry/react";
import { SupabaseClient } from "@supabase/supabase-js";
import { supabaseIntegration } from "@supabase/sentry-js-integration";
import { scrubBreadcrumb, scrubEvent, scrubSpan } from "./sentry-scrub";
import { SENTRY_APP_TAGS, sentryEnabled } from "./sentry";

export { captureException, captureReactException, setTag, setUser };

const supabaseUrl = (import.meta.env.VITE_SUPABASE_URL as string | undefined) ?? "";

/** What the Supabase integration calls on "the Sentry namespace": just these, so nothing else is kept. */
const sentryForSupabase = { addBreadcrumb, captureException, startInactiveSpan, SEMANTIC_ATTRIBUTE_SENTRY_OP, SEMANTIC_ATTRIBUTE_SENTRY_ORIGIN };

/** The options `startSentry` passes to `Sentry.init`. */
export function sentryOptions(router: unknown): BrowserOptions {
  return {
    dsn: import.meta.env.VITE_SENTRY_DSN as string | undefined,
    environment: ((import.meta.env.VITE_SENTRY_ENVIRONMENT as string | undefined) ?? "").trim(),
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
    // Error-only replay, fully masked. The integration itself is added by sentry-replay.ts,
    // which reads these rates from the client when it starts.
    replaysSessionSampleRate: 0,
    replaysOnErrorSampleRate: 1.0,
    tracePropagationTargets: supabaseUrl ? [supabaseUrl] : [],
    integrations: [
      tanstackRouterBrowserTracingIntegration(router, {
        // supabase-js calls get their own spans from the Supabase integration.
        shouldCreateSpanForRequest: (url: string) => !(supabaseUrl && url.startsWith(`${supabaseUrl}/rest/`)),
      }),
      supabaseIntegration(SupabaseClient, sentryForSupabase, {
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
  };
}

/**
 * Initialise the SDK, then fetch Replay in the background. Checks `sentryEnabled` again, so a
 * local build never reports even if something imports this module directly.
 */
export function startSentry(router: unknown): void {
  if (!sentryEnabled) return;
  init(sentryOptions(router));
  void import("./sentry-replay").then((m) => m.startReplay()).catch(() => {});
}
