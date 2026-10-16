// How testflight-distribute.mjs talks to App Store Connect when Apple is slow.
//
// On 2026-10-16 build 33's first API call got no answer: Node waits 300 s for
// response headers, then throws a bare "fetch failed", and the release step
// failed although the upload had worked. Each request now gets its own
// timeout, and a GET (safe to repeat) is retried on a network error, a
// timeout, 429 or 5xx. A POST is sent once: the script is re-runnable, and a
// retried submission whose first answer was lost would fail as a duplicate.

export const REQUEST_TIMEOUT_MS = 60_000;
export const RETRY_DELAYS_MS = [5_000, 15_000, 45_000];

const retryableStatus = (status) => status === 429 || status >= 500;

/**
 * send(signal) performs one request and resolves to `{ status, ... }`.
 * Returns the last response, or throws the last error with the attempt count.
 */
export async function withRetry(method, send, {
  timeoutMs = REQUEST_TIMEOUT_MS,
  delays = RETRY_DELAYS_MS,
  sleep = (ms) => new Promise((r) => setTimeout(r, ms)),
  log = () => {},
} = {}) {
  const attempts = method === 'GET' ? delays.length + 1 : 1;
  for (let attempt = 1; ; attempt++) {
    let res;
    let error;
    try {
      res = await send(AbortSignal.timeout(timeoutMs));
    } catch (e) {
      error = e;
    }
    const retryable = error !== undefined || retryableStatus(res.status);
    if (!retryable || attempt >= attempts) {
      if (error === undefined) return res;
      const why = error.cause?.code ?? error.name ?? 'error';
      throw new Error(`${error.message} (${why}) after ${attempt} attempt${attempt === 1 ? '' : 's'}`);
    }
    const wait = delays[attempt - 1];
    log(`${error ? `${error.message} (${error.cause?.code ?? error.name})` : `HTTP ${res.status}`}; retrying in ${wait / 1000} s`);
    await sleep(wait);
  }
}
