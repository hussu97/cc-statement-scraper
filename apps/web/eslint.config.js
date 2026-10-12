import js from "@eslint/js";
import globals from "globals";
import reactHooks from "eslint-plugin-react-hooks";
import reactRefresh from "eslint-plugin-react-refresh";
import tseslint from "typescript-eslint";

const SUPABASE_JS = { name: "@supabase/supabase-js", message: "Use the hooks in src/data instead.", allowTypeImports: true };
// WEB-11: a static import of the Sentry SDK puts it in the first-load bundle. lib/sentry.ts
// loads it after first paint (sentry-client.ts) and Replay after that (sentry-replay.ts).
const SENTRY_SDK = {
  group: ["@sentry/*", "@supabase/sentry-js-integration"],
  message: "Use the helpers in src/lib/sentry.ts; the SDK is loaded lazily.",
  allowTypeImports: true,
};

export default tseslint.config(
  { ignores: ["dist", "node_modules"] },
  {
    extends: [js.configs.recommended, ...tseslint.configs.recommended],
    files: ["**/*.{ts,tsx}"],
    languageOptions: { ecmaVersion: 2023, globals: globals.browser },
    plugins: { "react-hooks": reactHooks, "react-refresh": reactRefresh },
    rules: {
      ...reactHooks.configs.recommended.rules,
      "react-refresh/only-export-components": "off",
      "@typescript-eslint/no-unused-vars": ["error", { argsIgnorePattern: "^_", varsIgnorePattern: "^_" }],
      // Components never talk to Supabase directly: data access lives in src/data.
      "no-restricted-imports": ["error", { paths: [SUPABASE_JS], patterns: [SENTRY_SDK] }],
    },
  },
  {
    files: ["src/lib/supabase.ts", "src/data/**"],
    rules: { "no-restricted-imports": ["error", { patterns: [SENTRY_SDK] }] },
  },
  {
    // The lazily loaded Sentry chunks: the only static importers of the SDK.
    files: ["src/lib/sentry-client.ts", "src/lib/sentry-replay.ts", "vite.config.ts"],
    rules: { "no-restricted-imports": "off" },
  },
);
