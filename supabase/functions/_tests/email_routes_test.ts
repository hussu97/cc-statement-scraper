// Ports the behaviour of backend/scripts/email_ingestion_common.py route matching.
import { assert, assertEquals } from "jsr:@std/assert@1.0.13";
import {
  type EmailRoute,
  filenameAllowed,
  labelsAllowed,
  pickRoute,
  routeMatchesMessage,
  senderAllowed,
  senderFromFromHeader,
  subjectAllowed,
} from "../_shared/email_routes.ts";

function route(over: Partial<EmailRoute> = {}): EmailRoute {
  return {
    route_code: "rte_x",
    profile_code: "prf_x",
    mailbox_code: "mbx_x",
    bank_code: "FAB",
    sender_allowlist: [],
    subject_keywords: [],
    attachment_filename_regex: null,
    gmail_label_filter: [],
    ...over,
  };
}

Deno.test("sender allowlist: exact, case- and whitespace-insensitive; empty allows all", () => {
  assert(senderAllowed("anyone@x.com", []));
  assert(senderAllowed("anyone@x.com", null));
  assert(senderAllowed(" Statements@BankFAB.com ", ["statements@bankfab.com"]));
  assert(!senderAllowed("other@bankfab.com", ["statements@bankfab.com"]));
  assert(!senderAllowed("evil-statements@bankfab.com", ["statements@bankfab.com"]));
});

Deno.test("subject keywords: any substring, case-insensitive", () => {
  assert(subjectAllowed("Whatever", []));
  assert(subjectAllowed("Your Credit Card E-Statement", ["statement", "invoice"]));
  assert(!subjectAllowed("Promotion", ["statement"]));
  assert(subjectAllowed("x", ["  ", ""])); // blank keywords are ignored
});

Deno.test("filename regex: case-insensitive search; invalid regex never matches", () => {
  assert(filenameAllowed("a.pdf", null));
  assert(filenameAllowed("CC_Statement_0825.PDF", "statement.*\\.pdf$"));
  assert(!filenameAllowed("receipt.pdf", "statement"));
  assert(!filenameAllowed("statement.pdf", "(unclosed"));
});

Deno.test("gmail labels: any-of; skipped for providers without labels", () => {
  assert(labelsAllowed(["INBOX"], []));
  assert(labelsAllowed(["INBOX", "Label_7"], ["Label_7", "Label_9"]));
  assert(!labelsAllowed(["INBOX"], ["Label_7"]));
  assert(labelsAllowed(null, ["Label_7"]));
});

Deno.test("route matches only when every filter passes", () => {
  const r = route({
    sender_allowlist: ["estatements@fab.ae"],
    subject_keywords: ["statement"],
    attachment_filename_regex: "\\.pdf$",
  });
  const ok = { sender: "estatements@fab.ae", subject: "Your Statement", filename: "s.pdf", labels: ["INBOX"] };
  assert(routeMatchesMessage(r, ok));
  assert(!routeMatchesMessage(r, { ...ok, sender: "x@fab.ae" }));
  assert(!routeMatchesMessage(r, { ...ok, subject: "Offer" }));
  assert(!routeMatchesMessage(r, { ...ok, filename: "s.zip" }));
  assert(!routeMatchesMessage({ ...r, enabled: false }, ok));
});

Deno.test("pickRoute picks the first matching route by bank_code", () => {
  const routes = [route({ bank_code: "SIB", route_code: "rte_sib" }), route({ bank_code: "ADCB", route_code: "rte_adcb" })];
  assertEquals(pickRoute(routes, { sender: "a", subject: "b", filename: "c.pdf", labels: [] })?.route_code, "rte_adcb");
  const none = [route({ subject_keywords: ["nope"] })];
  assertEquals(pickRoute(none, { sender: "a", subject: "b", filename: "c.pdf", labels: [] }), null);
});

Deno.test("senderFromFromHeader extracts the address", () => {
  assertEquals(senderFromFromHeader('"FAB e-Statements" <EStatements@BankFAB.com>'), "estatements@bankfab.com");
  assertEquals(senderFromFromHeader("Plain@Example.com"), "plain@example.com");
  assertEquals(senderFromFromHeader(""), "");
});
