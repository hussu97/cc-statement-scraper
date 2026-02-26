import { useSyncExternalStore } from 'react';

const STORAGE_KEY = 'ccs_admin_token';

type Listener = () => void;

const listeners = new Set<Listener>();

function readInitialToken(): string {
  if (typeof window === 'undefined') {
    return '';
  }
  return window.localStorage.getItem(STORAGE_KEY) || '';
}

let adminToken = readInitialToken();

function notify() {
  listeners.forEach((listener) => listener());
}

export function getAdminToken(): string {
  return adminToken;
}

export function setAdminToken(token: string): void {
  adminToken = token.trim();

  if (typeof window !== 'undefined') {
    if (adminToken) {
      window.localStorage.setItem(STORAGE_KEY, adminToken);
    } else {
      window.localStorage.removeItem(STORAGE_KEY);
    }
  }

  notify();
}

export function clearAdminToken(): void {
  setAdminToken('');
}

function subscribe(listener: Listener): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function useAdminToken(): string {
  return useSyncExternalStore(subscribe, getAdminToken, () => '');
}
