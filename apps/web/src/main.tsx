import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { QueryClientProvider } from "@tanstack/react-query";
import { RouterProvider } from "@tanstack/react-router";
import "./styles.css";
import { router } from "./router";
import { initSentry } from "./lib/sentry";
import { createQueryClient } from "./data/query-client";
import { AuthProvider } from "./data/auth";
import { ProfileProvider } from "./data/profile";
import { ErrorBoundary } from "./components/error-boundary";
import { ErrorState } from "./components/ui/states";
import { supabaseConfigured } from "./lib/supabase";

// Sentry loads after first paint, and only in a deployed build (lib/sentry.ts).
// Toasts and tooltips are provided by AppShell, so the public pages carry no Radix (WEB-11).
initSentry(router);
const queryClient = createQueryClient();

function Root() {
  if (!supabaseConfigured) {
    return (
      <ErrorState
        className="min-h-dvh"
        title="Bank Ledger isn't configured"
        error={new Error("Set VITE_SUPABASE_URL and VITE_SUPABASE_PUBLISHABLE_KEY in apps/web/.env.local, then restart the dev server.")}
      />
    );
  }
  return (
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <ProfileProvider>
          <RouterProvider router={router} />
        </ProfileProvider>
      </AuthProvider>
    </QueryClientProvider>
  );
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <ErrorBoundary
      fallback={({ resetError }) => (
        <ErrorState className="min-h-dvh" title="Something broke on this screen" error={new Error("The error has been reported.")} onRetry={resetError} />
      )}
    >
      <Root />
    </ErrorBoundary>
  </StrictMode>,
);
