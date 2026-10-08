import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import type { Session } from "@supabase/supabase-js";
import { useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/lib/supabase";
import { setSentryUser } from "@/lib/sentry";
import { ApiError } from "./api";

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

/** Sends a magic link that also carries a 6-digit code. */
export async function sendMagicLink(email: string): Promise<void> {
  const { error } = await supabase.auth.signInWithOtp({
    email,
    options: { emailRedirectTo: `${window.location.origin}/`, shouldCreateUser: true },
  });
  check(error);
}

export async function verifyEmailCode(email: string, token: string): Promise<void> {
  const { error } = await supabase.auth.verifyOtp({ email, token, type: "email" });
  check(error);
}

export async function signOut(): Promise<void> {
  await supabase.auth.signOut();
}
