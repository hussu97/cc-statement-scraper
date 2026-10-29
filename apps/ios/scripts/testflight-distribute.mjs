#!/usr/bin/env node
//
// Release a finished TestFlight build of Ledger to the external tester group,
// so people who joined through the public link actually receive it. The same
// script as another app on the same Apple team, for one app, plus "What to Test".
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
//   node apps/ios/scripts/testflight-distribute.mjs --review-account   # only set the review sign-in
//
// --review-account writes the App Review demo account (Guideline 2.1(a): Beta App
// Review needs a username and password) into Test Information → Beta App Review
// Information, from $LEDGER_REVIEW_EMAIL / $LEDGER_REVIEW_PASSWORD, which
// scripts/cutover/create-review-demo.sh leaves in the gitignored .env.review-demo.
// The password is never printed.
//
// "What to Test" defaults to $LEDGER_WHAT_TO_TEST, else the subject of the last
// commit that touched apps/ios outside build-number.json. Not set when neither exists.
//
// Credentials — the same App Store Connect API key the upload uses:
//   ASC_KEY_ID, ASC_ISSUER_ID (required, no default: the repository is public), and either
//   ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8   (local; ASC_KEY_ID may be
//   omitted when it is the only key there)  or ASC_KEY_P8 holding the PEM or its base64 (CI)
//
// The app — its bundle id, kept out of git: $LEDGER_BUNDLE_ID (CI: the `testflight`
// environment secret), else LEDGER_BUNDLE_PREFIX from the gitignored
// apps/ios/Config/Identity.xcconfig (local).

import { execFileSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { withRetry } from './asc-retry.mjs';

const DEFAULT_GROUP = 'Friends & Family';

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
const REVIEW_ACCOUNT = args.includes('--review-account');

const fail = (msg) => {
  console.error(`error: ${msg}`);
  process.exit(1);
};

// ── the app (identity from the environment or the gitignored Identity.xcconfig) ──
const IOS_DIR = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
function identityValue(key) {
  const file = path.join(IOS_DIR, 'Config', 'Identity.xcconfig');
  if (!fs.existsSync(file)) return '';
  let value = '';
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    const m = line.match(new RegExp(`^\\s*${key}\\s*=\\s*(.*?)\\s*$`));
    if (m) value = m[1];
  }
  return value;
}
function bundleId() {
  const id = process.env.LEDGER_BUNDLE_ID || identityValue('LEDGER_BUNDLE_PREFIX');
  if (!id || id.startsWith('com.example.') || id.includes('<')) {
    fail(
      'no bundle id. Set LEDGER_BUNDLE_ID, or LEDGER_BUNDLE_PREFIX in apps/ios/Config/Identity.xcconfig\n' +
        '  (copy Config/Identity.example.xcconfig; in CI it is the testflight environment secret).'
    );
  }
  return id;
}
const APP = { scheme: 'Ledger', bundleId: bundleId(), label: 'Bank Ledger (iPhone)' };

function whatToTest() {
  const explicit = opt('--what-to-test', null) ?? process.env.LEDGER_WHAT_TO_TEST;
  if (explicit) return explicit.slice(0, 4000);
  try {
    const subject = execFileSync(
      'git',
      ['log', '-1', '--format=%s', '--', '.', ':(exclude)build-number.json'],
      { cwd: IOS_DIR, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }
    ).trim();
    return subject || null;
  } catch {
    return null;
  }
}

// ── auth ───────────────────────────────────────────────────────────────────
const KEY_DIR = path.join(os.homedir(), '.appstoreconnect', 'private_keys');
const ISSUER_ID = process.env.ASC_ISSUER_ID;
if (!ISSUER_ID) {
  fail('ASC_ISSUER_ID must be set (App Store Connect → Users and Access → Integrations → Issuer ID).');
}
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
  // A timeout per request, and GETs retried when Apple doesn't answer (asc-retry.mjs).
  return withRetry(method, async (signal) => {
    const res = await fetch(url, {
      method,
      headers: { Authorization: `Bearer ${token()}`, 'Content-Type': 'application/json' },
      body: body ? JSON.stringify(body) : undefined,
      signal,
    });
    const text = await res.text();
    let json = null;
    try {
      json = text ? JSON.parse(text) : null;
    } catch {
      json = { raw: text };
    }
    return { status: res.status, ok: res.ok, json };
  }, { log: (msg) => console.log(`[asc] ${method} ${endpoint}: ${msg}`) });
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

async function findApp() {
  // `filter[bundleId]` is a prefix match: pick the exact id out of the results.
  const appRes = await asc('GET', '/v1/apps', { query: { 'filter[bundleId]': APP.bundleId, limit: 200 } });
  if (!appRes.ok) throw new Error(`could not read apps: ${details(appRes)}`);
  const record = appRes.json.data?.find((a) => a.attributes.bundleId === APP.bundleId);
  if (!record) throw new Error(`no app in App Store Connect with bundle id ${APP.bundleId}`);
  say(`App: ${record.attributes.name} (${record.id})`);
  return record;
}

// ── Beta App Review Information: the demo account ──────────────────────────
const REVIEW_NOTES =
  'Bank Ledger is a personal finance app for one household; it has no open sign-up. ' +
  'On the sign-in screen tap "Sign in with a password" and use the demo account above. ' +
  'It opens a demo ledger filled with synthetic cards, statements, SMS alerts and budgets, so every tab has data.';

async function setReviewAccount() {
  const email = process.env.LEDGER_REVIEW_EMAIL;
  const password = process.env.LEDGER_REVIEW_PASSWORD;
  if (!email || !password) {
    fail('LEDGER_REVIEW_EMAIL and LEDGER_REVIEW_PASSWORD must be set (source .env.review-demo).');
  }
  const record = await findApp();
  const detail = await asc('GET', `/v1/apps/${record.id}/betaAppReviewDetail`);
  if (!detail.ok) throw new Error(`could not read Beta App Review Information: ${details(detail)}`);
  const res = await asc('PATCH', `/v1/betaAppReviewDetails/${detail.json.data.id}`, {
    body: {
      data: {
        type: 'betaAppReviewDetails',
        id: detail.json.data.id,
        attributes: {
          demoAccountRequired: true,
          demoAccountName: email,
          demoAccountPassword: password,
          notes: REVIEW_NOTES,
        },
      },
    },
  });
  if (!res.ok) throw new Error(`could not save the review account: ${details(res)}`);
  say(`Beta App Review sign-in set: ${email} (password not shown)`);
  return `${APP.label}: review account saved`;
}

async function distribute() {
  const record = await findApp();
  const appId = record.id;

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

  // Beta App Review can't get past sign-in without a demo account: builds 3 and 6
  // were rejected under Guideline 2.1(a). Don't submit a build that will bounce.
  const review = await asc('GET', `/v1/apps/${appId}/betaAppReviewDetail`);
  const reviewInfo = review.json?.data?.attributes;
  if (!review.ok || !reviewInfo?.demoAccountRequired || !reviewInfo?.demoAccountName) {
    throw new Error(
      `build ${build.attributes.version} attached but not submitted: Beta App Review Information has no demo account.\n` +
        `  Run scripts/cutover/create-review-demo.sh, then\n` +
        `  set -a; . .env.review-demo; set +a; node apps/ios/scripts/testflight-distribute.mjs --review-account\n` +
        `  and re-run with --build ${build.attributes.version}.`
    );
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
  if (REVIEW_ACCOUNT) {
    console.log(`\n✓ ${await setReviewAccount()}`);
    process.exit(0);
  }
  const summary = await distribute();
  console.log(`\n✓ ${summary}`);
  console.log(`\nDone. Testers in "${GROUP_NAME}" get this build once Apple approves it.`);
} catch (e) {
  console.error(`\n✗ ${APP.label}: ${e.message}`);
  process.exit(1);
}
