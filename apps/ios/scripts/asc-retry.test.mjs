// node --test apps/ios/scripts/asc-retry.test.mjs (run by release_checks_test.sh)
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { withRetry } from './asc-retry.mjs';

const fast = { delays: [1, 2, 3], sleep: async () => {} };
const failed = () => Object.assign(new TypeError('fetch failed'), { cause: { code: 'UND_ERR_HEADERS_TIMEOUT' } });

test('a GET that fails on the network is retried until it answers', async () => {
  let calls = 0;
  const res = await withRetry('GET', async () => {
    calls++;
    if (calls < 3) throw failed();
    return { status: 200 };
  }, fast);
  assert.equal(res.status, 200);
  assert.equal(calls, 3);
});

test('a GET answering 503 or 429 is retried; 404 is returned as is', async () => {
  const statuses = [503, 429, 200];
  assert.equal((await withRetry('GET', async () => ({ status: statuses.shift() }), fast)).status, 200);
  let calls = 0;
  const res = await withRetry('GET', async () => { calls++; return { status: 404 }; }, fast);
  assert.deepEqual([res.status, calls], [404, 1]);
});

test('a GET that never answers fails after every attempt, naming the cause', async () => {
  let calls = 0;
  await assert.rejects(
    withRetry('GET', async () => { calls++; throw failed(); }, fast),
    /fetch failed \(UND_ERR_HEADERS_TIMEOUT\) after 4 attempts/,
  );
  assert.equal(calls, 4);
});

test('the last 5xx is returned when retries run out', async () => {
  assert.equal((await withRetry('GET', async () => ({ status: 502 }), fast)).status, 502);
});

test('a POST is sent once, error or 5xx', async () => {
  let calls = 0;
  await assert.rejects(withRetry('POST', async () => { calls++; throw failed(); }, fast), /after 1 attempt$/);
  assert.equal((await withRetry('POST', async () => { calls++; return { status: 500 }; }, fast)).status, 500);
  assert.equal(calls, 2);
});

test('each attempt gets an abort signal', async () => {
  let seen;
  await withRetry('GET', async (signal) => { seen = signal; return { status: 200 }; }, fast);
  assert.ok(seen instanceof AbortSignal);
});
