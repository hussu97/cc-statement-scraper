// Deployment values that stay out of the repository and come from the build environment
// (Vercel project env), so a public checkout names no production host or Apple app:
//   - a <meta> Content-Security-Policy pinning connect-src/img-src to the one Supabase host
//     (VITE_SUPABASE_URL). vercel.json's header policy allows any *.supabase.co; a browser
//     enforces both, so the effective policy is this host only.
//   - /.well-known/apple-app-site-association (passkeys' webcredentials) from
//     LEDGER_APPLE_APP_IDS ("TEAMID.bundle.id", comma-separated). Not emitted when unset.
// The builders are pure and unit-tested (deploy-config.test.ts); the plugin only feeds them.
import type { Plugin } from "vite";

const SENTRY_INGEST = ["https://*.ingest.sentry.io", "https://*.ingest.us.sentry.io", "https://*.ingest.de.sentry.io"];

/** The https origin of a Supabase URL, or null when it isn't a hosted https URL. */
export function supabaseOrigin(url: string | undefined): string | null {
  if (!url) return null;
  try {
    const u = new URL(url);
    return u.protocol === "https:" ? u.origin : null;
  } catch {
    return null;
  }
}

/** The meta CSP for a hosted Supabase origin (https://<ref>.supabase.co). */
export function supabaseCsp(origin: string): string {
  const wss = origin.replace(/^https:/, "wss:");
  return [
    `connect-src 'self' ${origin} ${wss} ${SENTRY_INGEST.join(" ")}`,
    `img-src 'self' data: blob: ${origin}`,
  ].join("; ");
}

/** apple-app-site-association JSON for webcredentials, or null when no app ids are set. */
export function appleAppSiteAssociation(appIds: string | undefined): string | null {
  const apps = (appIds ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  if (apps.length === 0) return null;
  for (const id of apps) {
    if (!/^[A-Z0-9]{10}\.[A-Za-z0-9.-]+$/.test(id)) throw new Error(`LEDGER_APPLE_APP_IDS: "${id}" is not TEAMID.bundle.id`);
  }
  return JSON.stringify({ webcredentials: { apps } }, null, 2) + "\n";
}

export function deployConfig(env: Record<string, string | undefined> = process.env): Plugin {
  return {
    name: "ledger-deploy-config",
    apply: "build",
    transformIndexHtml() {
      const origin = supabaseOrigin(env.VITE_SUPABASE_URL);
      if (!origin) return [];
      return [{ tag: "meta", attrs: { "http-equiv": "Content-Security-Policy", content: supabaseCsp(origin) }, injectTo: "head-prepend" }];
    },
    generateBundle() {
      const aasa = appleAppSiteAssociation(env.LEDGER_APPLE_APP_IDS);
      if (aasa) this.emitFile({ type: "asset", fileName: ".well-known/apple-app-site-association", source: aasa });
    },
  };
}
