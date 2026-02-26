import { useSyncExternalStore } from 'react';

const STORAGE_KEY = 'ccs_auth_user';

export type AuthUser = {
  email: string;
  display_name: string;
  default_profile_key: string;
  role: string;
};

type Listener = () => void;

const listeners = new Set<Listener>();

function readInitialUser(): AuthUser | null {
  if (typeof window === 'undefined') {
    return null;
  }
  const raw = window.localStorage.getItem(STORAGE_KEY);
  if (!raw) {
    return null;
  }
  try {
    const parsed = JSON.parse(raw) as AuthUser;
    if (!parsed?.email) {
      return null;
    }
    return parsed;
  } catch {
    return null;
  }
}

let authUser: AuthUser | null = readInitialUser();

function notify() {
  listeners.forEach((listener) => listener());
}

export function getAuthUser(): AuthUser | null {
  return authUser;
}

export function setAuthUser(user: AuthUser | null): void {
  authUser = user;

  if (typeof window !== 'undefined') {
    if (authUser) {
      window.localStorage.setItem(STORAGE_KEY, JSON.stringify(authUser));
    } else {
      window.localStorage.removeItem(STORAGE_KEY);
    }
  }

  notify();
}

export function clearAuthUser(): void {
  setAuthUser(null);
}

function subscribe(listener: Listener): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function useAuthUser(): AuthUser | null {
  return useSyncExternalStore(subscribe, getAuthUser, () => null);
}
