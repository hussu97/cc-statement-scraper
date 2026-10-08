import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import type { Session } from "@supabase/supabase-js";
import { useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/lib/supabase";
import { setSentryUser } from "@/lib/sentry";
import { ApiError, errorMessage } from "./api";

interface AuthState {
  session: Session | null;
  userId: string | null;
  email: string | null;
  loading: boolean;
}

const AuthContext = createContext<AuthState>({ session: null, userId: null, email: null, loading: true });

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  const qc = useQueryClient();

  useEffect(() => {
    let mounted = true;
    supabase.auth.getSession().then(({ data }) => {
      if (!mounted) return;
      setSession(data.session);
      setLoading(false);
    });
    const { data } = supabase.auth.onAuthStateChange((event, next) => {
      setSession(next);
      setLoading(false);
      if (event === "SIGNED_OUT") qc.clear();
    });
    return () => {
      mounted = false;
      data.subscription.unsubscribe();
    };
  }, [qc]);

  useEffect(() => setSentryUser(session?.user.id ?? null), [session?.user.id]);

  const value = useMemo<AuthState>(
    () => ({ session, userId: session?.user.id ?? null, email: session?.user.email ?? null, loading }),
    [session, loading],
  );
  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthState {
  return useContext(AuthContext);
}

function check(error: { message: string; code?: string; status?: number } | null) {
  if (error) throw new ApiError(error.message, { code: error.code, status: error.status });
}

/**
 * Emails a one-time sign-in code. Existing accounts only: Bank Ledger is
 * invite-only, so an unknown email never creates a user (WEB-04). There is no
 * link in the email and no password sign-in: the code (or a passkey) is the only way in.
 */
export async function sendEmailCode(email: string): Promise<void> {
  const { error } = await supabase.auth.signInWithOtp({ email, options: emailCodeOptions() });
  check(error);
}

/** signInWithOtp options. Pure, so the no-sign-up, no-link guarantee is unit-tested. */
export function emailCodeOptions(): { shouldCreateUser: false } {
  return { shouldCreateUser: false };
}

/** Codes are 6–10 digits depending on the project's OTP length. */
export const CODE_MIN = 6;
export const CODE_MAX = 10;
export function cleanCode(raw: string): string {
  return raw.replace(/\D/g, "").slice(0, CODE_MAX);
}

export const NO_ACCOUNT_MESSAGE = "There's no Bank Ledger account for that email. Ask the ledger's owner to invite you.";

/** Sentences for sign-in failures people can act on. */
export function signInErrorMessage(error: unknown): string {
  const code = (error as { code?: string } | null)?.code ?? "";
  const msg = errorMessage(error);
  // GoTrue answers an OTP for an unknown email with shouldCreateUser=false like this.
  if (code === "otp_disabled" || code === "user_not_found" || /signups? not allowed|user not found/i.test(msg)) return NO_ACCOUNT_MESSAGE;
  if (code === "otp_expired" || /token has expired|otp.*(expired|invalid)/i.test(msg)) return "That code has expired or is wrong. Ask for a new code.";
  if (code === "over_email_send_rate_limit" || /rate limit/i.test(msg)) return "Too many emails sent. Wait a minute, then try again.";
  if (/error sending .*email/i.test(msg)) return "We couldn't send the email just now. Try again in a minute.";
  return passkeyErrorMessage(code) ?? msg;
}

/** Sentences for GoTrue's passkey error codes, or null when the code isn't one. */
export function passkeyErrorMessage(code: string): string | null {
  switch (code) {
    case "webauthn_credential_not_found":
      return "That passkey is no longer on your Bank Ledger account. Sign in with an email code, then add a new one.";
    case "webauthn_challenge_expired":
    case "webauthn_challenge_not_found":
      return "The passkey prompt timed out. Try again.";
    case "webauthn_verification_failed":
      return "The passkey couldn't be verified. Try again, or sign in with an email code.";
    case "webauthn_credential_exists":
      return "This device already has a passkey for your account.";
    case "too_many_passkeys":
      return "You've reached the passkey limit. Remove one in Settings → Account first.";
    case "passkey_disabled":
      return "Passkeys are turned off for Bank Ledger right now. Use an email code.";
    default:
      return null;
  }
}

export async function verifyEmailCode(email: string, token: string): Promise<void> {
  const { error } = await supabase.auth.verifyOtp({ email, token, type: "email" });
  check(error);
}

/** Discoverable passkey sign-in: no email needed. Resolves to false when the person cancels. */
export async function signInWithPasskey(opts?: { conditional?: boolean }): Promise<boolean> {
  const { error } = await supabase.auth.signInWithPasskey(opts?.conditional ? { options: { mediation: "conditional" } } : undefined);
  if (error && isPasskeyCancel(error)) return false;
  check(error);
  return true;
}

/** The browser's "cancelled / timed out / aborted" outcomes are not errors to show. */
export function isPasskeyCancel(error: unknown): boolean {
  const e = error as { code?: string; name?: string; message?: string; cause?: { name?: string } } | null;
  if (!e) return false;
  const names = [e.code, e.name, e.cause?.name];
  if (names.some((n) => n === "ERROR_CEREMONY_ABORTED" || n === "NotAllowedError" || n === "AbortError")) return true;
  return /not allowed|operation either timed out|aborted|cancel/i.test(e.message ?? "");
}

export async function signOut(): Promise<void> {
  await supabase.auth.signOut();
}
