import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { QueryClientProvider } from "@tanstack/react-query";
import { RouterProvider } from "@tanstack/react-router";
import "./styles.css";
import { router } from "./router";
import { initSentry, Sentry } from "./lib/sentry";
import { createQueryClient } from "./data/query-client";
import { AuthProvider } from "./data/auth";
import { ProfileProvider } from "./data/profile";
import { Toaster } from "./components/ui/toast";
import { TooltipProvider } from "./components/ui/primitives";
import { ErrorState } from "./components/ui/states";
import { supabaseConfigured } from "./lib/supabase";

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
          <TooltipProvider>
            <Toaster>
              <RouterProvider router={router} />
            </Toaster>
          </TooltipProvider>
        </ProfileProvider>
      </AuthProvider>
    </QueryClientProvider>
  );
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <Sentry.ErrorBoundary
      fallback={({ resetError }) => (
        <ErrorState className="min-h-dvh" title="Something broke on this screen" error={new Error("The error has been reported.")} onRetry={resetError} />
      )}
    >
      <Root />
    </Sentry.ErrorBoundary>
  </StrictMode>,
);
