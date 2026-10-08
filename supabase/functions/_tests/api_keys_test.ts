import { assertEquals, assertThrows } from "jsr:@std/assert@1.0.13";
import { keyFromDictionary, resolveApiKey } from "../_shared/supabase.ts";

const envOf = (vars: Record<string, string>) => (name: string) => vars[name];

Deno.test("keyFromDictionary prefers `default`, else the first key; tolerates junk", () => {
  assertEquals(keyFromDictionary('{"ci":"sb_secret_a","default":"sb_secret_b"}'), "sb_secret_b");
  assertEquals(keyFromDictionary('{"ci":"sb_secret_a"}'), "sb_secret_a");
  assertEquals(keyFromDictionary('{"default":""}'), null);
  assertEquals(keyFromDictionary("not json"), null);
  assertEquals(keyFromDictionary('["sb_secret_a"]'), null);
  assertEquals(keyFromDictionary(undefined), null);
});

Deno.test("secret key: runtime dictionary → SB_SECRET_KEY → legacy service_role", () => {
  const all = {
    SUPABASE_SECRET_KEYS: '{"default":"sb_secret_rt"}',
    SB_SECRET_KEY: "sb_secret_custom",
    SUPABASE_SERVICE_ROLE_KEY: "legacy.jwt.value",
  };
  assertEquals(resolveApiKey("secret", envOf(all)), { key: "sb_secret_rt", source: "SUPABASE_SECRET_KEYS" });
  const { SUPABASE_SECRET_KEYS: _a, ...noDict } = all;
  assertEquals(resolveApiKey("secret", envOf(noDict)), { key: "sb_secret_custom", source: "SB_SECRET_KEY" });
  assertEquals(resolveApiKey("secret", envOf({ SUPABASE_SERVICE_ROLE_KEY: "legacy.jwt.value" })), {
    key: "legacy.jwt.value",
    source: "SUPABASE_SERVICE_ROLE_KEY",
  });
  // A malformed dictionary falls through instead of failing the function.
  assertEquals(
    resolveApiKey("secret", envOf({ SUPABASE_SECRET_KEYS: "{", SB_SECRET_KEY: "sb_secret_custom" })).source,
    "SB_SECRET_KEY",
  );
});

Deno.test("publishable key: runtime dictionary → SB_PUBLISHABLE_KEY → legacy anon", () => {
  assertEquals(
    resolveApiKey("publishable", envOf({ SUPABASE_PUBLISHABLE_KEYS: '{"default":"sb_publishable_rt"}' })).key,
    "sb_publishable_rt",
  );
  assertEquals(
    resolveApiKey("publishable", envOf({ SB_PUBLISHABLE_KEY: "sb_publishable_c" })).source,
    "SB_PUBLISHABLE_KEY",
  );
  assertEquals(resolveApiKey("publishable", envOf({ SUPABASE_ANON_KEY: "anon.jwt" })).source, "SUPABASE_ANON_KEY");
});

Deno.test("missing keys fail with the env names, never a value", () => {
  assertThrows(() => resolveApiKey("secret", envOf({})), Error, "SUPABASE_SECRET_KEYS / SB_SECRET_KEY");
});
