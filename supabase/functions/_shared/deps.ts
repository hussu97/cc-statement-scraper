// Every third-party import for the Edge Functions lives here, pinned exactly.
// Functions import from this module only, so a version bump is a one-line change.
export { createClient } from "npm:@supabase/supabase-js@2.116.0";
export type { SupabaseClient } from "npm:@supabase/supabase-js@2.116.0";
export * as Sentry from "npm:@sentry/deno@10.75.0";
export { createLocalJWKSet, createRemoteJWKSet, jwtVerify } from "npm:jose@6.2.12";
export type { JWTPayload, JWTVerifyGetKey } from "npm:jose@6.2.12";
export { default as Anthropic } from "npm:@anthropic-ai/sdk@0.127.0";
