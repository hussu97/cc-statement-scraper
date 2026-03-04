import { getActiveProfileKey } from './profileStore';
import { clearAuthUser } from './authStore';

export type HttpMethod = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';

export class ApiError extends Error {
  status: number;
  data: unknown;
  constructor(status: number, statusText: string, data: unknown) {
    const detail = (data as { detail?: unknown } | null)?.detail;
    const displayMessage = typeof detail === 'string' ? detail : JSON.stringify(data);
    super(`HTTP ${status} ${statusText}: ${displayMessage}`);
    this.status = status;
    this.data = data;
  }
}

const API_BASE = (import.meta.env.VITE_API_BASE_URL ?? '').replace(/\/$/, '');
const API_PREFIX = `${API_BASE}/api/v1`;

async function request<T>(
  method: HttpMethod,
  path: string,
  body?: unknown,
  init?: RequestInit,
): Promise<T> {
  const headers: Record<string, string> = {};
  if (init?.headers) {
    const source = new Headers(init.headers);
    source.forEach((value, key) => {
      headers[key] = value;
    });
  }

  if (!headers['X-Profile-Key'] && !headers['x-profile-key']) {
    headers['X-Profile-Key'] = getActiveProfileKey();
  }

  let payload: BodyInit | undefined;
  if (body instanceof FormData) {
    payload = body;
  } else if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
    payload = JSON.stringify(body);
  }

  const resp = await fetch(`${API_PREFIX}${path}`, {
    method,
    headers,
    body: payload,
    credentials: 'include',
    ...init,
  });

  if (resp.status === 401) {
    clearAuthUser();
  }

  if (!resp.ok) {
    const text = await resp.text();
    let data: unknown;
    try {
      data = JSON.parse(text);
    } catch {
      data = text;
    }
    throw new ApiError(resp.status, resp.statusText, data);
  }

  if (resp.status === 204) {
    return undefined as T;
  }

  return (await resp.json()) as T;
}

async function downloadFile(path: string): Promise<{ blob: Blob; filename: string }> {
  const headers: Record<string, string> = {
    'X-Profile-Key': getActiveProfileKey(),
  };
  const resp = await fetch(`${API_PREFIX}${path}`, { method: 'GET', headers, credentials: 'include' });
  if (resp.status === 401) clearAuthUser();
  if (!resp.ok) {
    const text = await resp.text();
    let data: unknown;
    try {
      data = JSON.parse(text);
    } catch {
      data = text;
    }
    throw new ApiError(resp.status, resp.statusText, data);
  }
  const disposition = resp.headers.get('Content-Disposition') ?? '';
  const match = disposition.match(/filename=(.+)/);
  const filename = match ? match[1].trim() : 'export.xlsx';
  return { blob: await resp.blob(), filename };
}

export const api = {
  get: <T>(path: string, init?: RequestInit) => request<T>('GET', path, undefined, init),
  post: <T>(path: string, body?: unknown, init?: RequestInit) => request<T>('POST', path, body, init),
  put: <T>(path: string, body?: unknown, init?: RequestInit) => request<T>('PUT', path, body, init),
  patch: <T>(path: string, body?: unknown, init?: RequestInit) => request<T>('PATCH', path, body, init),
  delete: <T>(path: string, init?: RequestInit) => request<T>('DELETE', path, undefined, init),
  upload: <T>(path: string, form: FormData, init?: RequestInit) => request<T>('POST', path, form, init),
  downloadFile,
};
