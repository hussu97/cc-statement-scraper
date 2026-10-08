import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/lib/supabase";
import { readStorage, writeStorage } from "@/lib/storage";
import { setSentryProfile } from "@/lib/sentry";
import { useAuth } from "./auth";
import { keys } from "./keys";
import { must, mustList } from "./api";

export interface ProfileSummary {
  profile_code: string;
  key: string;
  name: string;
  base_currency: string;
  role: "owner" | "viewer";
}

const STORAGE_KEY = "ledger.profile";

/** Pick the active profile: the stored one if still accessible, else the first. */
export function chooseActiveProfile(profiles: ProfileSummary[], stored: string | null): ProfileSummary | null {
  if (profiles.length === 0) return null;
  return profiles.find((p) => p.profile_code === stored) ?? profiles[0] ?? null;
}

export function useProfiles() {
  const { userId } = useAuth();
  return useQuery({
    queryKey: [...keys.profiles, userId],
    enabled: !!userId,
    queryFn: async (): Promise<ProfileSummary[]> => {
      const rows = mustList(
        await supabase
          .from("profile_members")
          .select("role, profiles!inner(profile_code, key, name, base_currency)")
          .eq("user_id", userId!),
      );
      return rows
        .map((r) => {
          const p = r.profiles as unknown as Omit<ProfileSummary, "role">;
          return { ...p, role: r.role as ProfileSummary["role"] };
        })
        .sort((a, b) => a.name.localeCompare(b.name));
    },
  });
}

interface ProfileContextValue {
  profile: ProfileSummary | null;
  profiles: ProfileSummary[];
  isOwner: boolean;
  setActive: (code: string) => void;
  loading: boolean;
  error: unknown;
}

const ProfileContext = createContext<ProfileContextValue | null>(null);

export function ProfileProvider({ children }: { children: ReactNode }) {
  const q = useProfiles();
  const qc = useQueryClient();
  const [stored, setStored] = useState<string | null>(() => readStorage(STORAGE_KEY));
  const profiles = useMemo(() => q.data ?? [], [q.data]);
  const profile = useMemo(() => chooseActiveProfile(profiles, stored), [profiles, stored]);

  useEffect(() => setSentryProfile(profile?.profile_code ?? null), [profile?.profile_code]);

  const setActive = useCallback(
    (code: string) => {
      writeStorage(STORAGE_KEY, code);
      setStored(code);
      void qc.invalidateQueries({ queryKey: ["p", code] });
    },
    [qc],
  );

  const value = useMemo<ProfileContextValue>(
    () => ({ profile, profiles, isOwner: profile?.role === "owner", setActive, loading: q.isLoading, error: q.error }),
    [profile, profiles, setActive, q.isLoading, q.error],
  );
  return <ProfileContext.Provider value={value}>{children}</ProfileContext.Provider>;
}

export function useProfileContext(): ProfileContextValue {
  const ctx = useContext(ProfileContext);
  if (!ctx) throw new Error("useProfileContext outside ProfileProvider");
  return ctx;
}

/** The active profile; screens under the app shell can rely on it existing. */
export function useActiveProfile(): ProfileSummary & { isOwner: boolean } {
  const { profile } = useProfileContext();
  if (!profile) throw new Error("No active profile");
  return { ...profile, isOwner: profile.role === "owner" };
}

/** Suggest a profile key (^[a-z0-9_-]{2,40}$) from a display name. */
export function profileKeyFromName(name: string): string {
  const base = name
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 32);
  return base.length >= 2 ? base : `ledger-${base || "me"}`;
}

export function useCreateProfile() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async ({ name, key }: { name: string; key: string }) =>
      must(await supabase.rpc("create_profile", { p_key: key, p_name: name })) as string,
    onSuccess: async (code) => {
      writeStorage(STORAGE_KEY, code);
      await qc.invalidateQueries({ queryKey: keys.profiles });
    },
  });
}
