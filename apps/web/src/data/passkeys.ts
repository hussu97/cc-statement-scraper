import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/lib/supabase";
import { readStorage, writeStorage } from "@/lib/storage";
import { ApiError } from "./api";
import { isPasskeyCancel, passkeyErrorMessage } from "./auth";
import { keys } from "./keys";

export interface Passkey {
  id: string;
  friendly_name?: string;
  created_at: string;
  last_used_at?: string;
}

function check(error: { message: string; code?: string; status?: number } | null) {
  if (!error) return;
  throw new ApiError(passkeyErrorMessage(error.code ?? "") ?? error.message, { code: error.code, status: error.status });
}

/** WebAuthn is available in this browser (not a guarantee a platform authenticator exists). */
export function passkeysSupported(w: { PublicKeyCredential?: unknown } = globalThis as never): boolean {
  return typeof w.PublicKeyCredential === "function";
}

/** Conditional UI (passkey autofill in the email field) is available. */
export async function conditionalMediationAvailable(): Promise<boolean> {
  const pkc = (globalThis as { PublicKeyCredential?: { isConditionalMediationAvailable?: () => Promise<boolean> } }).PublicKeyCredential;
  try {
    return (await pkc?.isConditionalMediationAvailable?.()) ?? false;
  } catch {
    return false;
  }
}

/** A readable default name: "Safari on Mac", "Chrome on Windows". */
export function defaultPasskeyName(ua: string): string {
  const os = /iPhone/.test(ua) ? "iPhone" : /iPad/.test(ua) ? "iPad" : /Android/.test(ua) ? "Android" : /Mac OS X|Macintosh/.test(ua) ? "Mac" : /Windows/.test(ua) ? "Windows" : /Linux/.test(ua) ? "Linux" : "this device";
  const browser = /Edg\//.test(ua) ? "Edge" : /Firefox\//.test(ua) ? "Firefox" : /Chrome\//.test(ua) ? "Chrome" : /Safari\//.test(ua) ? "Safari" : "Browser";
  return `${browser} on ${os}`;
}

// "Not now" on the sign-in offer is remembered per user, in this browser only.
const offerKey = (userId: string) => `ledger.passkey-offer.${userId}`;

export function passkeyOfferDeclined(userId: string): boolean {
  return readStorage(offerKey(userId)) === "declined";
}

export function setPasskeyOfferDeclined(userId: string, declined: boolean): void {
  writeStorage(offerKey(userId), declined ? "declined" : null);
}

/** Offer a passkey after an email-code sign-in only when it can help and wasn't declined. */
export function shouldOfferPasskey(input: { supported: boolean; declined: boolean; passkeyCount: number | null }): boolean {
  return input.supported && !input.declined && input.passkeyCount === 0;
}

export async function listPasskeys(): Promise<Passkey[]> {
  const { data, error } = await supabase.auth.passkey.list();
  check(error);
  return data ?? [];
}

/** Registers a passkey and names it for this device. Resolves to null when the person cancels. */
export async function registerPasskey(name = defaultPasskeyName(navigator.userAgent)): Promise<Passkey | null> {
  const { data, error } = await supabase.auth.registerPasskey();
  if (error && isPasskeyCancel(error)) return null;
  check(error);
  if (!data) return null;
  if (!data.friendly_name && name) {
    const renamed = await supabase.auth.passkey.update({ passkeyId: data.id, friendlyName: name.slice(0, 120) });
    if (!renamed.error && renamed.data) return renamed.data;
  }
  return data;
}

export function usePasskeys(userId: string | null) {
  return useQuery({ queryKey: keys.passkeys(userId ?? ""), queryFn: listPasskeys, enabled: !!userId });
}

export function useRegisterPasskey(userId: string | null) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: () => registerPasskey(),
    onSuccess: () => qc.invalidateQueries({ queryKey: keys.passkeys(userId ?? "") }),
  });
}

export function useRenamePasskey(userId: string | null) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (v: { id: string; name: string }) => {
      const { error } = await supabase.auth.passkey.update({ passkeyId: v.id, friendlyName: v.name.trim().slice(0, 120) });
      check(error);
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: keys.passkeys(userId ?? "") }),
  });
}

export function useDeletePasskey(userId: string | null) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.auth.passkey.delete({ passkeyId: id });
      check(error);
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: keys.passkeys(userId ?? "") }),
  });
}
