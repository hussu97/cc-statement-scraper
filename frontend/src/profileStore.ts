import { useSyncExternalStore } from 'react';

const STORAGE_KEY = 'ccs.active_profile_key';
const DEFAULT_PROFILE_KEY = 'hussain';

type Listener = () => void;

const listeners = new Set<Listener>();

function loadInitialProfileKey(): string {
  if (typeof window === 'undefined') {
    return DEFAULT_PROFILE_KEY;
  }
  try {
    const stored = window.localStorage.getItem(STORAGE_KEY);
    if (stored && stored.trim()) {
      return stored.trim().toLowerCase();
    }
  } catch {
    // Ignore localStorage access issues and use default.
  }
  return DEFAULT_PROFILE_KEY;
}

let activeProfileKey = loadInitialProfileKey();

function notify() {
  listeners.forEach((listener) => listener());
}

export function getActiveProfileKey(): string {
  return activeProfileKey;
}

export function setActiveProfileKey(nextKey: string): void {
  const normalized = (nextKey || '').trim().toLowerCase() || DEFAULT_PROFILE_KEY;
  if (normalized === activeProfileKey) {
    return;
  }
  activeProfileKey = normalized;
  if (typeof window !== 'undefined') {
    try {
      window.localStorage.setItem(STORAGE_KEY, activeProfileKey);
    } catch {
      // Ignore localStorage write issues.
    }
  }
  notify();
}

function subscribe(listener: Listener): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function useActiveProfileKey(): string {
  return useSyncExternalStore(subscribe, getActiveProfileKey, getActiveProfileKey);
}
