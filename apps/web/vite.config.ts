/// <reference types="vitest/config" />
import { fileURLToPath, URL } from "node:url";
import { defineConfig, type PluginOption } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { sentryVitePlugin } from "@sentry/vite-plugin";
import { bundleBudget } from "./scripts/bundle-budget.ts";

// Source maps are uploaded to Sentry (and then deleted from the bundle) only
// when SENTRY_AUTH_TOKEN is present, i.e. in the Vercel/CI build.
const sentryPlugins: PluginOption[] = process.env.SENTRY_AUTH_TOKEN
  ? [
      sentryVitePlugin({
        org: process.env.SENTRY_ORG,
        project: process.env.SENTRY_PROJECT ?? "credit-card-ledger-apps",
        authToken: process.env.SENTRY_AUTH_TOKEN,
        release: { name: process.env.VITE_SENTRY_RELEASE ?? process.env.VERCEL_GIT_COMMIT_SHA },
        sourcemaps: { filesToDeleteAfterUpload: ["./dist/**/*.map"] },
        telemetry: false,
      }),
    ]
  : [];

// The commit a build came from, as <meta name="ledger-build">: web-smoke.yml reads it off
// production to know Vercel shipped a push, since Vercel doesn't always report its
// deployments back to GitHub. Not a secret: the repository's own commit id.
const buildStamp: PluginOption = {
  name: "ledger-build-stamp",
  transformIndexHtml: () => [
    { tag: "meta", attrs: { name: "ledger-build", content: process.env.VERCEL_GIT_COMMIT_SHA ?? "local" }, injectTo: "head" },
  ],
};

export default defineConfig({
  plugins: [react(), tailwindcss(), buildStamp, bundleBudget(), ...sentryPlugins],
  resolve: { alias: { "@": fileURLToPath(new URL("./src", import.meta.url)) } },
  build: {
    sourcemap: process.env.SENTRY_AUTH_TOKEN ? "hidden" : false,
    rolldownOptions: {
      output: {
        // React and supabase-js are on every route (auth runs before the first screen): named
        // vendor chunks, so the first-load list reads honestly instead of borrowing an app
        // module's name, and they stay cached across app deploys (WEB-11).
        codeSplitting: {
          groups: [
            { name: "react", test: /[\\/]node_modules[\\/](react|react-dom|scheduler)[\\/]/ },
            { name: "supabase", test: /[\\/]node_modules[\\/]@supabase[\\/](?!sentry-js-integration[\\/])/ },
          ],
        },
      },
    },
  },
  server: { port: 5173, host: "127.0.0.1" },
  test: {
    environment: "node",
    include: ["src/**/*.test.ts", "src/**/*.test.tsx", "scripts/**/*.test.ts"],
  },
});
