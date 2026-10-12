// Integration test against the running local stack. Skipped unless LEDGER_E2E=1.
//
//   supabase start
//   supabase functions serve --env-file supabase/functions/.env
//   cd supabase/functions && LEDGER_E2E=1 deno test -A _tests/e2e_local_test.ts
//
// Creates its own user, profile and service token (so it survives `supabase db reset`
// by other agents) and removes them afterwards. Uses synthetic PDFs only.

import { assert, assertEquals } from "jsr:@std/assert@1.0.13";
import { createClient } from "../_shared/deps.ts";

const enabled = Deno.env.get("LEDGER_E2E") === "1";

async function localKeys(): Promise<{ url: string; anon: string; service: string }> {
  const url = Deno.env.get("SUPABASE_URL") ?? "http://127.0.0.1:54321";
  // Publishable / secret keys (sb_publishable_… / sb_secret_…); legacy JWT keys only as a fallback.
  let anon = Deno.env.get("SB_PUBLISHABLE_KEY") ?? "";
  let service = Deno.env.get("SB_SECRET_KEY") ?? "";
  if (!anon || !service) {
    const out = await new Deno.Command("supabase", { args: ["status", "-o", "json"], stdout: "piped", stderr: "null" })
      .output();
    const status = JSON.parse(new TextDecoder().decode(out.stdout));
    anon ||= status.PUBLISHABLE_KEY || status.ANON_KEY;
    service ||= status.SECRET_KEY || status.SERVICE_ROLE_KEY;
  }
  return { url, anon, service };
}

function syntheticPdf(tag: string): Uint8Array {
  return new TextEncoder().encode(`%PDF-1.4\n% ledger e2e ${tag}\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n`);
}

Deno.test({
  name: "e2e: statements-upload (legacy token + JWT), dedup, auth failures; sms-ingest",
  ignore: !enabled,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const { url, anon, service } = await localKeys();
    const fnUrl = `${url}/functions/v1`;
    const svc = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });
    const rand = crypto.randomUUID().slice(0, 8);
    const email = `e2e-${rand}@ledger.test`;
    const password = crypto.randomUUID();
    let userId: string | null = null;
    let viewerId: string | null = null;
    let inviteeId: string | null = null;
    let profileCode: string | null = null;
    const storedPaths: string[] = [];

    try {
      const created = await svc.auth.admin.createUser({ email, password, email_confirm: true });
      assert(!created.error, created.error?.message);
      userId = created.data.user!.id;
      const pub = createClient(url, anon, { auth: { persistSession: false, autoRefreshToken: false } });
      const signIn = await pub.auth.signInWithPassword({ email, password });
      assert(!signIn.error, signIn.error?.message);
      const jwt = signIn.data.session!.access_token;
      const user = createClient(url, anon, {
        auth: { persistSession: false, autoRefreshToken: false },
        global: { headers: { Authorization: `Bearer ${jwt}` } },
      });

      const prof = await user.rpc("create_profile", { p_key: `e2e${rand}`, p_name: "E2E" });
      assert(!prof.error, prof.error?.message);
      profileCode = prof.data as string;
      const tok = await user.rpc("create_service_token", {
        p_profile_code: profileCode,
        p_name: "e2e",
        p_scopes: ["statements:upload", "sms:ingest"],
      });
      assert(!tok.error, tok.error?.message);
      const token = (tok.data as { token: string }).token;

      // ── legacy scraper contract ──
      const legacyUpload = (bytes: Uint8Array, headers: Record<string, string>, extra: Record<string, string> = {}) => {
        const form = new FormData();
        form.append("files", new File([bytes as BlobPart], `FAB_${rand}.pdf`, { type: "application/pdf" }));
        for (const [k, v] of Object.entries(extra)) form.append(k, v);
        return fetch(`${fnUrl}/statements-upload`, { method: "POST", headers, body: form });
      };
      const tokenHeaders = { Authorization: `Bearer ${token}`, "X-Profile-Key": `e2e${rand}` };
      const pdf = syntheticPdf(rand);

      const r1 = await legacyUpload(pdf, tokenHeaders, { bank_code_hint: "fab" });
      const b1 = await r1.json();
      assertEquals(r1.status, 200, JSON.stringify(b1));
      assertEquals(b1.uploads.length, 1);
      assertEquals(b1.uploads[0].status, "queued");
      const docCode = b1.uploads[0].doc_code as string;
      assert(/^doc_[0-9a-z]{26}$/.test(docCode));

      const { data: doc } = await svc.from("documents").select("*").eq("doc_code", docCode).single();
      assertEquals(doc.profile_code, profileCode);
      assertEquals(doc.source, "scraper");
      assertEquals(doc.bank_code, "FAB");
      assertEquals(doc.storage_path, `${profileCode}/${docCode}.pdf`);
      assertEquals(doc.parse_status, "queued");
      assertEquals(doc.size_bytes, pdf.length);
      storedPaths.push(doc.storage_path);
      const obj = await svc.storage.from("statements").download(doc.storage_path);
      assert(!obj.error, "object missing from storage");
      assertEquals((await obj.data!.arrayBuffer()).byteLength, pdf.length);

      const r2 = await legacyUpload(pdf, tokenHeaders);
      const b2 = await r2.json();
      assertEquals(r2.status, 200);
      assertEquals(b2.uploads[0], {
        filename: `FAB_${rand}.pdf`,
        doc_code: docCode,
        status: "duplicate",
        parse_status: "queued",
      });

      // SRV-20: re-sending a PDF whose parse failed queues it again.
      await svc.from("documents").update({ parse_status: "failed", parse_error_code: "PDF_DECRYPT_FAILED" })
        .eq("doc_code", docCode);
      const rq = await legacyUpload(pdf, tokenHeaders);
      const brq = await rq.json();
      assertEquals(brq.uploads[0].requeued, true, JSON.stringify(brq));
      assertEquals(brq.uploads[0].parse_status, "queued");
      const { data: requeued } = await svc.from("documents").select("parse_status, parse_error_code")
        .eq("doc_code", docCode).single();
      assertEquals(requeued, { parse_status: "queued", parse_error_code: null });

      // ── auth failures ──
      assertEquals(
        (await (await legacyUpload(pdf, { Authorization: "Bearer ccs_nope" })).json()).error.code,
        "UNAUTHORIZED",
      );
      const wrongKey = await legacyUpload(pdf, { ...tokenHeaders, "X-Profile-Key": "someone-else" });
      assertEquals(wrongKey.status, 401);
      await wrongKey.body?.cancel();
      const noAuth = await legacyUpload(pdf, {});
      assertEquals(noAuth.status, 401);
      await noAuth.body?.cancel();
      const notPdf = await legacyUpload(new TextEncoder().encode("hello"), tokenHeaders);
      assertEquals(notPdf.status, 422);
      await notPdf.body?.cancel();

      // ── user JWT (web / iOS) ──
      const jwtHeaders = { Authorization: `Bearer ${jwt}` };
      const missingProfile = await legacyUpload(syntheticPdf(`${rand}-ios`), jwtHeaders);
      assertEquals(missingProfile.status, 422);
      await missingProfile.body?.cancel();
      const otherProfile = await legacyUpload(syntheticPdf(`${rand}-ios`), jwtHeaders, {
        profile_code: "prf_00000000000000000000000000",
      });
      assertEquals(otherProfile.status, 403);
      await otherProfile.body?.cancel();
      const r3 = await legacyUpload(syntheticPdf(`${rand}-ios`), jwtHeaders, {
        profile_code: profileCode,
        source: "ios",
      });
      const b3 = await r3.json();
      assertEquals(r3.status, 200, JSON.stringify(b3));
      assertEquals(b3.uploads[0].status, "queued");
      const { data: doc3 } = await svc.from("documents").select("source, storage_path").eq(
        "doc_code",
        b3.uploads[0].doc_code,
      )
        .single();
      assertEquals(doc3!.source, "ios");
      storedPaths.push(doc3!.storage_path);

      // ── sms-ingest (token and JWT), idempotent on client_msg_id ──
      const msgId = crypto.randomUUID();
      const smsBody = {
        messages: [{
          client_msg_id: msgId,
          sender: "E2E",
          body: `e2e synthetic ${rand}`,
          received_at: new Date().toISOString(),
        }],
      };
      const s1 = await fetch(`${fnUrl}/sms-ingest`, {
        method: "POST",
        headers: { Authorization: `Bearer ${token}`, "content-type": "application/json" },
        body: JSON.stringify(smsBody),
      });
      const sb1 = await s1.json();
      assertEquals(s1.status, 200, JSON.stringify(sb1));
      assertEquals(sb1[0].client_msg_id, msgId);
      assert(/^sms_/.test(sb1[0].sms_code));
      const s2 = await fetch(`${fnUrl}/sms-ingest`, {
        method: "POST",
        headers: { Authorization: `Bearer ${jwt}`, "content-type": "application/json" },
        body: JSON.stringify({ profile_code: profileCode, ...smsBody }),
      });
      const sb2 = await s2.json();
      assertEquals(s2.status, 200, JSON.stringify(sb2));
      assertEquals(sb2[0].status, "duplicate_delivery");
      assertEquals(sb2[0].sms_code, sb1[0].sms_code);
      const s3 = await fetch(`${fnUrl}/sms-ingest`, {
        method: "POST",
        headers: { Authorization: `Bearer ${jwt}`, "content-type": "application/json" },
        body: JSON.stringify(smsBody),
      });
      assertEquals(s3.status, 422); // JWT callers must name the profile
      await s3.body?.cancel();

      // ── cron-only functions reject callers without the secret ──
      const w = await fetch(`${fnUrl}/worker`, { method: "POST", headers: { "x-cron-secret": "wrong" } });
      assertEquals(w.status, 401);
      await w.body?.cancel();

      // ── a viewer can read but never upload or ingest SMS (SRV-11) ──
      const viewerEmail = `e2e-viewer-${rand}@ledger.test`;
      const vCreated = await svc.auth.admin.createUser({ email: viewerEmail, password, email_confirm: true });
      assert(!vCreated.error, vCreated.error?.message);
      viewerId = vCreated.data.user!.id;
      const addViewer = await user.rpc("add_profile_member", {
        p_profile_code: profileCode,
        p_email: viewerEmail,
        p_role: "viewer",
      });
      assertEquals(addViewer.data, "added");
      const vSignIn = await pub.auth.signInWithPassword({ email: viewerEmail, password });
      assert(!vSignIn.error, vSignIn.error?.message);
      const viewerJwt = vSignIn.data.session!.access_token;
      const vUpload = await legacyUpload(syntheticPdf(`${rand}-viewer`), { Authorization: `Bearer ${viewerJwt}` }, {
        profile_code: profileCode,
      });
      assertEquals(vUpload.status, 403, "viewer upload");
      await vUpload.body?.cancel();
      const vSms = await fetch(`${fnUrl}/sms-ingest`, {
        method: "POST",
        headers: { Authorization: `Bearer ${viewerJwt}`, "content-type": "application/json" },
        body: JSON.stringify({ profile_code: profileCode, ...smsBody }),
      });
      assertEquals(vSms.status, 403, "viewer SMS ingest");
      await vSms.body?.cancel();

      // ── member-invite (NEW-1): owner invites, viewer can't, resend has a cooldown ──
      const invitee = `e2e-invitee-${rand}@ledger.test`;
      const invite = (jwtToken: string, body: Record<string, unknown>) =>
        fetch(`${fnUrl}/member-invite`, {
          method: "POST",
          headers: { Authorization: `Bearer ${jwtToken}`, "content-type": "application/json" },
          body: JSON.stringify({ profile_code: profileCode, email: invitee, ...body }),
        });
      const vInvite = await invite(viewerJwt, {});
      assertEquals(vInvite.status, 403, "viewer invite");
      await vInvite.body?.cancel();
      const i1 = await invite(jwt, {});
      const ib1 = await i1.json();
      assertEquals(i1.status, 200, JSON.stringify(ib1));
      assertEquals(ib1, { status: "invited", invite_sent: true });
      // The invite created an unconfirmed Auth user; the membership stays pending until the
      // address is confirmed (DB-23).
      const { data: invitedList } = await user.rpc("list_profile_members", { p_profile_code: profileCode });
      const invited = (invitedList as { email: string; user_id: string | null; pending: boolean }[])
        .find((m) => m.email === invitee);
      assert(invited && invited.pending && !invited.user_id, "the invitee is pending until confirmed");
      const { data: authUsers } = await svc.auth.admin.listUsers({ page: 1, perPage: 1000 });
      const invitedUser = authUsers.users.find((u) => u.email === invitee);
      assert(invitedUser && invitedUser.invited_at && !invitedUser.email_confirmed_at, "unconfirmed invited user");
      inviteeId = invitedUser.id;
      const i2 = await invite(jwt, { action: "resend" });
      const ib2 = await i2.json();
      assertEquals(i2.status, 429, JSON.stringify(ib2));
      assertEquals(ib2.error.code, "INVITE_COOLDOWN");
      const i3 = await invite(jwt, { action: "invite" });
      assertEquals(
        await i3.json(),
        { status: "invited", invite_sent: false, invite_error: "INVITE_COOLDOWN" },
        "re-inviting within the cooldown sends nothing",
      );
      const evil = await invite(jwt, { redirect_to: "https://evil.example/" });
      assertEquals(evil.status, 422);
      await evil.body?.cancel();

      // ── delete_profile archives: the profile disappears for its owner, its PDFs stay ──
      const del = await user.rpc("delete_profile", { p_profile_code: profileCode, p_confirm_key: `e2e${rand}` });
      assert(!del.error, del.error?.message);
      const after = await user.from("profiles").select("profile_code").eq("profile_code", profileCode);
      assertEquals(after.data?.length ?? 0, 0, "an archived profile is invisible to its owner");
      for (const path of storedPaths) {
        const kept = await svc.storage.from("statements").download(path);
        assert(!kept.error, `${path} should be kept`);
      }
    } finally {
      if (storedPaths.length) await svc.storage.from("statements").remove(storedPaths);
      if (profileCode) {
        // Rules first: deleting them through the profile cascade trips the rules
        // trigger's profile_state upsert (see the report / pending DB fix).
        await svc.from("category_rules").delete().eq("profile_code", profileCode);
        const del = await svc.from("profiles").delete().eq("profile_code", profileCode);
        if (del.error) console.warn(`e2e cleanup: profile ${profileCode} not deleted (${del.error.code})`);
      }
      for (const id of [userId, viewerId, inviteeId]) if (id) await svc.auth.admin.deleteUser(id);
    }
  },
});
