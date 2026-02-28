import { getActiveProfileKey } from './profileStore';
import { clearAuthUser } from './authStore';

export type HttpMethod = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';

const API_PREFIX = '/api/v1';

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
    throw new Error(`HTTP ${resp.status} ${resp.statusText}: ${text}`);
  }

  if (resp.status === 204) {
    return undefined as T;
  }

  return (await resp.json()) as T;
}

export const api = {
  get: <T>(path: string, init?: RequestInit) => request<T>('GET', path, undefined, init),
  post: <T>(path: string, body?: unknown, init?: RequestInit) => request<T>('POST', path, body, init),
  put: <T>(path: string, body?: unknown, init?: RequestInit) => request<T>('PUT', path, body, init),
  patch: <T>(path: string, body?: unknown, init?: RequestInit) => request<T>('PATCH', path, body, init),
  delete: <T>(path: string, init?: RequestInit) => request<T>('DELETE', path, undefined, init),
  upload: <T>(path: string, form: FormData, init?: RequestInit) => request<T>('POST', path, form, init),
};
