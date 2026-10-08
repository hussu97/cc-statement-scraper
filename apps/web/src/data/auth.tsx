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

export async function signInWithPassword(email: string, password: string): Promise<void> {
  const { error } = await supabase.auth.signInWithPassword({ email, password });
  check(error);
}

/**
 * Sends a magic link that also carries a 6-digit code. Existing accounts only:
 * Ledger is invite-only, so an unknown email never creates a user (WEB-04).
 */
export async function sendMagicLink(email: string): Promise<void> {
  const { error } = await supabase.auth.signInWithOtp({ email, options: magicLinkOptions(window.location.origin) });
  check(error);
}

/** signInWithOtp options. Pure, so the no-sign-up guarantee is unit-tested. */
export function magicLinkOptions(origin: string): { emailRedirectTo: string; shouldCreateUser: false } {
  return { emailRedirectTo: `${origin}/`, shouldCreateUser: false };
}

export const NO_ACCOUNT_MESSAGE = "There's no Ledger account for that email. Ask the ledger's owner to invite you.";

/** Sentences for sign-in failures people can act on. */
export function signInErrorMessage(error: unknown): string {
  const code = (error as { code?: string } | null)?.code ?? "";
  const msg = errorMessage(error);
  // GoTrue answers an OTP for an unknown email with shouldCreateUser=false like this.
  if (code === "otp_disabled" || code === "user_not_found" || /signups? not allowed|user not found/i.test(msg)) return NO_ACCOUNT_MESSAGE;
  if (code === "invalid_credentials" || /invalid login credentials/i.test(msg)) return "That email and password don't match.";
  if (code === "otp_expired" || /token has expired|otp.*(expired|invalid)/i.test(msg)) return "That code has expired or is wrong. Ask for a new link.";
  if (code === "over_email_send_rate_limit" || /rate limit/i.test(msg)) return "Too many emails sent. Wait a minute, then try again.";
  return msg;
}

export async function verifyEmailCode(email: string, token: string): Promise<void> {
  const { error } = await supabase.auth.verifyOtp({ email, token, type: "email" });
  check(error);
}

export async function signOut(): Promise<void> {
  await supabase.auth.signOut();
}
