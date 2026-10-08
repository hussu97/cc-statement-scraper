// Routes reachable without signing in. Everything else lives under the
// authenticated AppShell layout, which redirects to /signin.
export const PUBLIC_PATHS = ["/signin", "/privacy"] as const;

export const PRIVACY_LAST_UPDATED = "2026-10-08";
export const PRIVACY_CONTACT_EMAIL = "h_abbasi97@hotmail.com";
