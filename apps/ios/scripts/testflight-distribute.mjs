#!/usr/bin/env node
//
// Release a finished TestFlight build of Ledger to the external tester group,
// so people who joined through the public link actually receive it. A port of
// mm-pos/scripts/testflight-distribute.mjs for one app, plus "What to Test".
//
// Uploading a build only makes it appear in App Store Connect; external
// testers see nothing until it is attached to their group AND cleared by Beta
// App Review. `hasAccessToAllBuilds` only works for *internal* groups (on an
// external group it is silently ignored), which is why "Bank Ledger Internal" needs
// nothing here and "Friends & Family" needs all of this.
//
// Pure Node, no Xcode: runs on a Linux runner at 1x billing.
//
// Usage:
//   node apps/ios/scripts/testflight-distribute.mjs                    # latest build
//   node apps/ios/scripts/testflight-distribute.mjs --build 12         # a specific build number
//   node apps/ios/scripts/testflight-distribute.mjs --timeout 40       # minutes to wait for processing
//   node apps/ios/scripts/testflight-distribute.mjs --no-submit        # attach only, skip Beta App Review
//   node apps/ios/scripts/testflight-distribute.mjs --what-to-test "…" # this build's "What to Test"
//
// "What to Test" defaults to $LEDGER_WHAT_TO_TEST, else the subject of the last
// commit that touched apps/ios outside build-number.json. Not set when neither exists.
//
// Credentials — the same App Store Connect API key the upload uses:
//   ASC_KEY_ID, ASC_ISSUER_ID, and either
//   ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8   (local; ASC_KEY_ID may be
//   omitted when it is the only key there)  or ASC_KEY_P8 holding the PEM or its base64 (CI)

import { execFileSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const APP = { scheme: 'Ledger', bundleId: 'com.hussu97.ledger', label: 'Bank Ledger (iPhone)' };
const DEFAULT_GROUP = 'Friends & Family';
const DEFAULT_ISSUER = 'c43e9dbf-d873-4aa3-b89d-b5ef25d6accd';

// ── args ───────────────────────────────────────────────────────────────────
const args = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = args.indexOf(name);
  return i === -1 ? fallback : args[i + 1];
};
const BUILD_NUMBER = opt('--build', null);
const GROUP_NAME = opt('--group', DEFAULT_GROUP);
const TIMEOUT_MIN = Number(opt('--timeout', '25'));
const SUBMIT = !args.includes('--no-submit');

const fail = (msg) => {
  console.error(`error: ${msg}`);
  process.exit(1);
};

function whatToTest() {
  const explicit = opt('--what-to-test', null) ?? process.env.LEDGER_WHAT_TO_TEST;
  if (explicit) return explicit.slice(0, 4000);
  try {
    const repo = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
    const subject = execFileSync(
      'git',
      ['log', '-1', '--format=%s', '--', '.', ':(exclude)build-number.json'],
      { cwd: repo, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }
    ).trim();
    return subject || null;
  } catch {
    return null;
  }
}

// ── auth ───────────────────────────────────────────────────────────────────
const KEY_DIR = path.join(os.homedir(), '.appstoreconnect', 'private_keys');
const ISSUER_ID = process.env.ASC_ISSUER_ID || DEFAULT_ISSUER;
let KEY_ID = process.env.ASC_KEY_ID;
if (!KEY_ID && !process.env.ASC_KEY_P8 && fs.existsSync(KEY_DIR)) {
  const keys = fs.readdirSync(KEY_DIR).filter((n) => /^AuthKey_.+\.p8$/.test(n));
  if (keys.length === 1) KEY_ID = keys[0].slice('AuthKey_'.length, -'.p8'.length);
}

let cachedKey = null;
function privateKey() {
  if (cachedKey) return cachedKey;
  if (process.env.ASC_KEY_P8) {
    const raw = process.env.ASC_KEY_P8;
    cachedKey = raw.includes('BEGIN PRIVATE KEY') ? raw : Buffer.from(raw, 'base64').toString('utf8');
    return cachedKey;
  }
  const file = path.join(KEY_DIR, `AuthKey_${KEY_ID}.p8`);
  if (!fs.existsSync(file)) {
    fail(
      `no App Store Connect key found.\n` +
        `  Set ASC_KEY_P8, or place the key at ${file}\n` +
        `  (App Store Connect → Users and Access → Integrations → App Store Connect API)`
    );
  }
  cachedKey = fs.readFileSync(file, 'utf8');
  return cachedKey;
}

const b64url = (buf) =>
  Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

function token() {
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' }));
  const payload = b64url(JSON.stringify({ iss: ISSUER_ID, iat: now, exp: now + 900, aud: 'appstoreconnect-v1' }));
  const sig = crypto.sign('sha256', Buffer.from(`${header}.${payload}`), {
    key: crypto.createPrivateKey(privateKey()),
    dsaEncoding: 'ieee-p1363',
  });
  return `${header}.${payload}.${b64url(sig)}`;
}

async function asc(method, endpoint, { query, body } = {}) {
  const url = new URL(`https://api.appstoreconnect.apple.com${endpoint}`);
  for (const [k, v] of Object.entries(query ?? {})) url.searchParams.set(k, v);
  const res = await fetch(url, {
    method,
    headers: { Authorization: `Bearer ${token()}`, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = { raw: text };
  }
  return { status: res.status, ok: res.ok, json };
}

const details = (r) => (r.json?.errors ?? []).map((e) => e.detail || e.title).join('; ') || `HTTP ${r.status}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const say = (msg) => console.log(`[${APP.scheme}] ${msg}`);

// ── "What to Test" for this build (en-US) ──────────────────────────────────
async function setWhatToTest(build, text) {
  if (!text) {
    say('No "What to Test" text; leaving it unset');
    return;
  }
  const existing = await asc('GET', `/v1/builds/${build.id}/betaBuildLocalizations`, { query: { limit: 50 } });
  const loc = existing.json?.data?.find((l) => l.attributes.locale === 'en-US') ?? existing.json?.data?.[0];
  const r = loc
    ? await asc('PATCH', `/v1/betaBuildLocalizations/${loc.id}`, {
        body: { data: { type: 'betaBuildLocalizations', id: loc.id, attributes: { whatsNew: text } } },
      })
    : await asc('POST', '/v1/betaBuildLocalizations', {
        body: {
          data: {
            type: 'betaBuildLocalizations',
            attributes: { locale: 'en-US', whatsNew: text },
            relationships: { build: { data: { type: 'builds', id: build.id } } },
          },
        },
      });
  say(r.ok ? `What to Test: ${text.split('\n')[0]}` : `(What to Test not set: ${details(r)})`);
}

async function distribute() {
  // `filter[bundleId]` is a prefix match: pick the exact id out of the results.
  const appRes = await asc('GET', '/v1/apps', { query: { 'filter[bundleId]': APP.bundleId, limit: 200 } });
  if (!appRes.ok) throw new Error(`could not read apps: ${details(appRes)}`);
  const record = appRes.json.data?.find((a) => a.attributes.bundleId === APP.bundleId);
  if (!record) throw new Error(`no app in App Store Connect with bundle id ${APP.bundleId}`);
  const appId = record.id;
  say(`App: ${record.attributes.name} (${appId})`);

  // The group must already exist. Creating one here would mint a *new* public
  // link every time, silently invalidating the link people have been given.
  const groupsRes = await asc('GET', `/v1/apps/${appId}/betaGroups`, { query: { limit: 100 } });
  if (!groupsRes.ok) throw new Error(`could not list beta groups: ${details(groupsRes)}`);
  const group = groupsRes.json.data?.find((g) => g.attributes.name === GROUP_NAME);
  if (!group) {
    throw new Error(
      `no beta group named "${GROUP_NAME}" on ${record.attributes.name}.\n` +
        `  Existing groups: ${groupsRes.json.data?.map((g) => g.attributes.name).join(', ') || '(none)'}\n` +
        `  Create it in App Store Connect → TestFlight, or pass --group.`
    );
  }
  const link = group.attributes.publicLink ? ` (${group.attributes.publicLink})` : '';
  say(`Group: ${GROUP_NAME}${link}`);

  // ── find the build, waiting for Apple to finish processing ───────────────
  const deadline = Date.now() + TIMEOUT_MIN * 60_000;
  let build = null;
  while (Date.now() < deadline) {
    const query = { 'filter[app]': appId, limit: 20, sort: '-uploadedDate' };
    if (BUILD_NUMBER) query['filter[version]'] = BUILD_NUMBER;
    const res = await asc('GET', '/v1/builds', { query });
    if (!res.ok) throw new Error(`could not list builds: ${details(res)}`);
    const candidate = res.json.data?.[0];
    if (candidate) {
      const state = candidate.attributes.processingState;
      if (state === 'VALID') {
        build = candidate;
        break;
      }
      if (state === 'FAILED' || state === 'INVALID') {
        throw new Error(`build ${candidate.attributes.version} finished processing as ${state}.`);
      }
      say(`build ${candidate.attributes.version} is ${state}; waiting…`);
    } else {
      say(`build ${BUILD_NUMBER ?? '(latest)'} not visible yet; waiting…`);
    }
    await sleep(60_000);
  }
  if (!build) {
    throw new Error(
      `timed out after ${TIMEOUT_MIN} min waiting for ${BUILD_NUMBER ? `build ${BUILD_NUMBER}` : 'a processed build'}.\n` +
        `  Processing occasionally takes longer; re-run this script to pick up where it left off.`
    );
  }
  say(`Build ${build.attributes.version} is processed`);

  await setWhatToTest(build, whatToTest());

  // ── attach to the group (idempotent) ─────────────────────────────────────
  const attach = await asc('POST', `/v1/betaGroups/${group.id}/relationships/builds`, {
    body: { data: [{ type: 'builds', id: build.id }] },
  });
  say(attach.ok ? `Added build ${build.attributes.version} to "${GROUP_NAME}"` : `(attach returned ${attach.status}: ${details(attach)})`);

  // ── submit for Beta App Review ───────────────────────────────────────────
  if (!SUBMIT) {
    say('Skipping Beta App Review submission (--no-submit)');
    return `${APP.label}: build ${build.attributes.version} attached, not submitted`;
  }
  const detailRes = await asc('GET', `/v1/builds/${build.id}/buildBetaDetail`);
  const externalState = detailRes.json?.data?.attributes?.externalBuildState;
  say(`External state: ${externalState}`);
  if (externalState !== 'READY_FOR_BETA_SUBMISSION') {
    say('No submission needed');
    return `${APP.label}: build ${build.attributes.version} attached (${externalState})`;
  }

  const sub = await asc('POST', '/v1/betaAppReviewSubmissions', {
    body: {
      data: { type: 'betaAppReviewSubmissions', relationships: { build: { data: { type: 'builds', id: build.id } } } },
    },
  });
  if (sub.ok) {
    say('Submitted for Beta App Review');
    return `${APP.label}: build ${build.attributes.version} submitted for review`;
  }
  const why = details(sub);
  // Only one build per version train may be in review at a time: not a failure.
  if (/already in beta review|same train/i.test(why)) {
    say(`Not submitted yet: ${why}`);
    say(`re-run with: node apps/ios/scripts/testflight-distribute.mjs --build ${build.attributes.version}`);
    return `${APP.label}: build ${build.attributes.version} attached, queued behind the build ahead of it`;
  }
  if (/missing requi?red data/i.test(why)) {
    throw new Error(
      `Beta App Review submission failed: ${why}\n` +
        `  App Store Connect → ${record.attributes.name} → TestFlight → Test Information is incomplete:\n` +
        `  beta description, feedback email, privacy policy URL, or the review contact (phone number).`
    );
  }
  throw new Error(`Beta App Review submission failed: ${why}`);
}

// ── main ───────────────────────────────────────────────────────────────────
if (!KEY_ID) fail('ASC_KEY_ID must be set (or exactly one AuthKey_*.p8 in ~/.appstoreconnect/private_keys).');

try {
  const summary = await distribute();
  console.log(`\n✓ ${summary}`);
  console.log(`\nDone. Testers in "${GROUP_NAME}" get this build once Apple approves it.`);
} catch (e) {
  console.error(`\n✗ ${APP.label}: ${e.message}`);
  process.exit(1);
}
