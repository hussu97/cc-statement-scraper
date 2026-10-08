// sms-ingest: bank SMS from the iPhone App Intent (or automation), batch-capable so
// the iOS offline outbox can flush. Idempotent on client_msg_id.
//
// Auth (verify_jwt=false; checked here):
//   * User JWT: body.profile_code required; RPC ingest_sms runs through the user's
//     client, so its assert_member(owner) check applies.
//   * Service token with scope `sms:ingest`: the profile is the token's.
//
// Body: {profile_code?, messages: [{client_msg_id, received_at?, sender, body}]} (≤200)
// Response 200: the ingest_sms result array, verbatim:
//   [{client_msg_id, sms_code, status, txn_code?}]. SMS bodies are never logged.

import { withSentry } from "../_shared/sentry.ts";
import { requireUserOrServiceToken } from "../_shared/auth.ts";
import { HttpError, json, pgErrorToHttp, readJson, requireMethod } from "../_shared/http.ts";
import { serviceClient } from "../_shared/supabase.ts";
import { validateSmsRequest } from "./validate.ts";

async function handler(req: Request): Promise<Response> {
  requireMethod(req, "POST");
  const caller = await requireUserOrServiceToken(req, "sms:ingest");
  const body = validateSmsRequest(await readJson(req, 1_000_000));

  let profileCode: string;
  let client;
  if (caller.kind === "token") {
    if (body.profile_code && body.profile_code !== caller.profileCode) {
      throw new HttpError(403, "FORBIDDEN", "profile_code does not match the service token");
    }
    profileCode = caller.profileCode;
    client = serviceClient();
  } else {
    if (!body.profile_code) throw new HttpError(422, "PROFILE_REQUIRED", "profile_code is required");
    profileCode = body.profile_code;
    client = caller.client;
  }

  const { data, error } = await client.rpc("ingest_sms", { p_profile_code: profileCode, p_messages: body.messages });
  if (error) throw pgErrorToHttp(error, "SMS ingest failed");
  return json(data ?? [], 200, req);
}

Deno.serve(withSentry("sms-ingest", handler));
