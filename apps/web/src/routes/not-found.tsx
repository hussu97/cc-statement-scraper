import { Link } from "@tanstack/react-router";
import { useAuth } from "@/data/auth";
import { cn } from "@/lib/cn";
import { AppShell } from "@/components/shell";
import { Splash, ThemeToggle } from "@/components/chrome";
import { BrandLockup } from "@/components/brand/brand";

function NotFound({ className }: { className?: string }) {
  return (
    <div className={cn("flex flex-col items-center justify-center gap-2 px-6 py-10 text-center", className)}>
      <h1 className="font-display text-[28px] leading-tight font-normal tracking-[-0.01em] text-ink">This page doesn't exist</h1>
      <p className="max-w-sm text-sm text-muted">Check the address, or head back to your overview.</p>
      <Link to="/" className="tap mt-2 text-sm text-accent underline underline-offset-2">
        Go to overview
      </Link>
    </div>
  );
}

/**
 * The 404 (WEB-52). Signed in, it renders inside the app shell, so navigation stays one
 * click away; signed out, it is a plain page (a bad address doesn't send you to sign-in).
 */
export function NotFoundPage() {
  const { session, loading } = useAuth();
  if (loading) return <Splash />;
  if (session) {
    return (
      <AppShell>
        <NotFound className="min-h-[60dvh]" />
      </AppShell>
    );
  }
  return (
    <div className="flex min-h-dvh flex-col bg-bg">
      <div className="flex items-center justify-between gap-3 px-gutter pt-[max(1rem,env(safe-area-inset-top))] pb-4 md:px-gutter-lg">
        <BrandLockup to="/signin" />
        <ThemeToggle />
      </div>
      <main className="flex flex-1 items-center justify-center pb-[10vh]">
        <NotFound />
      </main>
    </div>
  );
}
