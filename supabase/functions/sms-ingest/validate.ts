// Pure request validation for sms-ingest. Never echoes message bodies in errors.

import { HttpError } from "../_shared/http.ts";

export const MAX_MESSAGES = 200;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export interface SmsIn {
  client_msg_id: string;
  received_at?: string;
  sender: string;
  body: string;
}

export interface SmsRequest {
  profile_code: string | null;
  messages: SmsIn[];
}

export function validateSmsRequest(raw: unknown): SmsRequest {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new HttpError(400, "INVALID_BODY", "expected a JSON object");
  const r = raw as Record<string, unknown>;
  let profile: string | null = null;
  if (r.profile_code !== undefined && r.profile_code !== null) {
    if (typeof r.profile_code !== "string" || !/^prf_[0-9a-z]{26}$/.test(r.profile_code)) {
      throw new HttpError(422, "INVALID_PROFILE", "profile_code is not a profile code");
    }
    profile = r.profile_code;
  }
  if (!Array.isArray(r.messages) || r.messages.length === 0) {
    throw new HttpError(422, "INVALID_MESSAGES", "messages must be a non-empty array");
  }
  if (r.messages.length > MAX_MESSAGES) {
    throw new HttpError(422, "TOO_MANY_MESSAGES", `at most ${MAX_MESSAGES} messages per request`);
  }
  const messages: SmsIn[] = r.messages.map((m, i) => {
    if (!m || typeof m !== "object") throw new HttpError(422, "INVALID_MESSAGE", `messages[${i}] is not an object`);
    const x = m as Record<string, unknown>;
    if (typeof x.client_msg_id !== "string" || !UUID.test(x.client_msg_id)) {
      throw new HttpError(422, "INVALID_MESSAGE", `messages[${i}].client_msg_id must be a UUID`);
    }
    if (typeof x.body !== "string" || !x.body.trim() || x.body.length > 2000) {
      throw new HttpError(422, "INVALID_MESSAGE", `messages[${i}].body must be 1–2000 characters`);
    }
    if (x.sender !== undefined && x.sender !== null && (typeof x.sender !== "string" || x.sender.length > 100)) {
      throw new HttpError(422, "INVALID_MESSAGE", `messages[${i}].sender must be a string of at most 100 characters`);
    }
    let received: string | undefined;
    if (x.received_at !== undefined && x.received_at !== null) {
      if (typeof x.received_at !== "string" || Number.isNaN(Date.parse(x.received_at))) {
        throw new HttpError(422, "INVALID_MESSAGE", `messages[${i}].received_at must be an ISO timestamp`);
      }
      received = x.received_at;
    }
    return {
      client_msg_id: x.client_msg_id.toLowerCase(),
      received_at: received,
      sender: typeof x.sender === "string" ? x.sender : "",
      body: x.body,
    };
  });
  return { profile_code: profile, messages };
}
