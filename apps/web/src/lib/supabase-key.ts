/**
 * The browser only ever gets the publishable key (`sb_publishable_…`, or a legacy anon JWT
 * during migration). A secret key (`sb_secret_…`) bypasses RLS and Supabase rejects it from
 * browsers, so it is treated as "not configured" rather than shipped.
 */
export function publishableKey(raw: string | undefined): string | null {
  const key = raw?.trim();
  if (!key) return null;
  if (key.startsWith("sb_secret_")) return null;
  return key;
}
