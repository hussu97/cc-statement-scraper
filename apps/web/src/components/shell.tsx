import { useState, type ReactNode } from "react";
import { Link, Navigate, Outlet, useRouterState } from "@tanstack/react-router";
import {
  ChartColumnBig,
  ChevronsUpDown,
  CreditCard,
  Inbox,
  LayoutGrid,
  LogOut,
  Menu as MenuIcon,
  Monitor,
  Moon,
  Plus,
  ReceiptText,
  Settings2,
  Shapes,
  Sun,
  Target,
  Check,
} from "lucide-react";
import { cn } from "@/lib/cn";
import { formatBadgeCount } from "@/lib/money";
import { useAuth, signOut } from "@/data/auth";
import { useProfileContext } from "@/data/profile";
import { useRealtimeInvalidation } from "@/data/realtime";
import { useOpenReviewCount } from "@/data/reviews";
import { applyTheme, readTheme, type ThemePref } from "@/lib/theme";
import { Menu, MenuContent, MenuItem, MenuLabel, MenuSeparator, MenuTrigger, Segmented } from "./ui/primitives";
import { Sheet } from "./ui/dialog";
import { ErrorState } from "./ui/states";
import { BrandLockup, BrandMark } from "./brand/brand";
import { BRAND_NAME } from "@/lib/brand";

interface NavItem {
  to: string;
  label: string;
  icon: ReactNode;
  badge?: number;
}

function useNav(profileCode: string | null): NavItem[] {
  const reviews = useOpenReviewCount(profileCode);
  const open = profileCode ? (reviews.data ?? 0) : 0;
  return [
    { to: "/", label: "Overview", icon: <LayoutGrid /> },
    { to: "/activity", label: "Activity", icon: <ReceiptText /> },
    { to: "/insights", label: "Insights", icon: <ChartColumnBig /> },
    { to: "/budgets", label: "Budgets", icon: <Target /> },
    { to: "/cards", label: "Cards & statements", icon: <CreditCard /> },
    { to: "/review", label: "Review", icon: <Inbox />, badge: open || undefined },
    { to: "/rules", label: "Rules", icon: <Shapes /> },
    { to: "/settings", label: "Settings", icon: <Settings2 /> },
  ];
}

function useIsActive() {
  const path = useRouterState({ select: (s) => s.location.pathname });
  // A statement page belongs to "Cards & statements".
  return (to: string) => (to === "/" ? path === "/" : path === to || path.startsWith(`${to}/`) || (to === "/cards" && path.startsWith("/statements/")));
}

export function ThemeToggle({ className }: { className?: string }) {
  const [pref, setPref] = useState<ThemePref>(() => readTheme());
  return (
    <Segmented<ThemePref>
      ariaLabel="Theme"
      className={className}
      value={pref}
      onChange={(v) => {
        setPref(v);
        applyTheme(v);
      }}
      options={[
        { value: "light", label: <Sun className="size-3.5" aria-label="Light" /> },
        { value: "system", label: <Monitor className="size-3.5" aria-label="System" /> },
        { value: "dark", label: <Moon className="size-3.5" aria-label="Dark" /> },
      ]}
    />
  );
}

function ProfileSwitcher({ compact }: { compact?: boolean }) {
  const { profile, profiles, setActive } = useProfileContext();
  const { email } = useAuth();
  return (
    <Menu>
      <MenuTrigger asChild>
        <button
          type="button"
          className={cn(
            "flex w-full min-w-0 items-center gap-2.5 rounded-md text-left transition-colors hover:bg-surface-2",
            compact ? "h-10 px-2" : "px-2 py-2",
          )}
          aria-label="Switch ledger"
        >
          <span className="flex size-7 shrink-0 items-center justify-center rounded-pill bg-accent-soft font-display text-sm text-accent">
            {(profile?.name ?? "?").slice(0, 1).toUpperCase()}
          </span>
          <span className="min-w-0 flex-1">
            <span className="block truncate text-[13px] font-medium text-ink">{profile?.name}</span>
            {!compact && <span className="block truncate text-[11px] text-subtle">{profile?.role === "viewer" ? "Viewer" : "Owner"}</span>}
          </span>
          <ChevronsUpDown className="size-3.5 shrink-0 text-subtle" aria-hidden />
        </button>
      </MenuTrigger>
      <MenuContent align="start" className="w-60">
        <MenuLabel>Ledgers</MenuLabel>
        {profiles.map((p) => (
          <MenuItem key={p.profile_code} onSelect={() => setActive(p.profile_code)}>
            <span className="flex-1 truncate">{p.name}</span>
            {p.role === "viewer" && <span className="text-[11px] text-subtle">viewer</span>}
            {p.profile_code === profile?.profile_code && <Check className="size-3.5 text-accent" />}
          </MenuItem>
        ))}
        <MenuItem asChild>
          <Link to="/welcome" search={{ new: 1 }}>
            <Plus className="size-3.5" /> Create another ledger
          </Link>
        </MenuItem>
        <MenuSeparator />
        <MenuLabel>{email}</MenuLabel>
        <MenuItem onSelect={() => void signOut()}>
          <LogOut className="size-3.5" /> Sign out
        </MenuItem>
      </MenuContent>
    </Menu>
  );
}

function Wordmark() {
  return <BrandLockup to="/" className="px-2" />;
}

function Sidebar({ nav }: { nav: NavItem[] }) {
  const isActive = useIsActive();
  return (
    <aside className="sticky top-0 hidden h-dvh w-60 shrink-0 flex-col border-r border-border bg-bg px-3 py-5 lg:flex">
      <Wordmark />
      <nav aria-label="Main" className="mt-8 flex flex-1 flex-col gap-0.5">
        {nav.map((n) => (
          <Link
            key={n.to}
            to={n.to}
            aria-current={isActive(n.to) ? "page" : undefined}
            className={cn(
              "group flex h-9 items-center gap-3 rounded-md px-2.5 text-[13.5px] transition-colors [&_svg]:size-4",
              isActive(n.to) ? "bg-surface text-ink shadow-[inset_0_0_0_1px_var(--color-border)]" : "text-muted hover:bg-surface-2 hover:text-ink",
            )}
          >
            <span className={cn(isActive(n.to) ? "text-accent" : "text-subtle group-hover:text-ink-2")}>{n.icon}</span>
            <span className="flex-1">{n.label}</span>
            {n.badge ? <span className="tabular rounded-pill bg-accent px-1.5 text-[11px] leading-[18px] font-medium text-accent-ink">{formatBadgeCount(n.badge)}</span> : null}
          </Link>
        ))}
      </nav>
      <div className="flex flex-col gap-3 border-t border-border pt-3">
        <ThemeToggle className="self-start" />
        <ProfileSwitcher />
      </div>
    </aside>
  );
}

/** Bottom-bar tabs on mobile; Review (the daily action surface) is one of them, Cards moves to More. */
const MOBILE_TABS = ["/", "/activity", "/insights", "/review"];

function MobileNav({ nav }: { nav: NavItem[] }) {
  const isActive = useIsActive();
  const [more, setMore] = useState(false);
  const tabs = nav.filter((n) => MOBILE_TABS.includes(n.to));
  const rest = nav.filter((n) => !MOBILE_TABS.includes(n.to));
  const restBadge = rest.reduce((s, n) => s + (n.badge ?? 0), 0);
  const moreActive = rest.some((n) => isActive(n.to));
  return (
    <>
      <header className="sticky top-0 z-30 flex h-[calc(3.5rem+env(safe-area-inset-top))] items-center justify-between gap-3 border-b border-border bg-bg/90 pt-[env(safe-area-inset-top)] pr-[max(1rem,env(safe-area-inset-right))] pl-[max(1rem,env(safe-area-inset-left))] backdrop-blur lg:hidden">
        <Wordmark />
        <div className="w-48 min-w-0 shrink">
          <ProfileSwitcher compact />
        </div>
      </header>
      <nav
        aria-label="Main"
        className="fixed inset-x-0 bottom-0 z-30 grid grid-cols-5 border-t border-border bg-surface/95 pb-[env(safe-area-inset-bottom)] backdrop-blur lg:hidden"
      >
        {tabs.map((n) => (
          <Link
            key={n.to}
            to={n.to}
            aria-current={isActive(n.to) ? "page" : undefined}
            aria-label={n.badge ? `${n.label}, ${n.badge} open` : undefined}
            className={cn("relative flex h-14 flex-col items-center justify-center gap-1 text-[10.5px] [&_svg]:size-5", isActive(n.to) ? "text-accent" : "text-muted")}
          >
            {n.icon}
            <span>{n.label.split(" ")[0]}</span>
            {n.badge ? (
              <span aria-hidden className="tabular absolute top-1.5 left-1/2 ml-1.5 min-w-[18px] rounded-pill bg-accent px-1 text-center text-[10.5px] leading-[18px] font-medium text-accent-ink">
                {formatBadgeCount(n.badge)}
              </span>
            ) : null}
          </Link>
        ))}
        <button
          type="button"
          onClick={() => setMore(true)}
          className={cn("relative flex h-14 flex-col items-center justify-center gap-1 text-[10.5px]", moreActive ? "text-accent" : "text-muted")}
        >
          <MenuIcon className="size-5" />
          <span>More</span>
          {restBadge > 0 && <span className="absolute top-2 right-[calc(50%-18px)] size-2 rounded-pill bg-accent" aria-label={`${restBadge} to review`} />}
        </button>
      </nav>
      <Sheet open={more} onOpenChange={setMore} title="More">
        <nav className="flex flex-col gap-1" aria-label="More">
          {rest.map((n) => (
            <Link key={n.to} to={n.to} onClick={() => setMore(false)} className="flex h-11 items-center gap-3 rounded-md px-2 text-sm text-ink hover:bg-surface-2 [&_svg]:size-4 [&_svg]:text-subtle">
              {n.icon}
              <span className="flex-1">{n.label}</span>
              {n.badge ? <span className="tabular rounded-pill bg-accent px-1.5 text-[11px] text-accent-ink">{formatBadgeCount(n.badge)}</span> : null}
            </Link>
          ))}
        </nav>
        <div className="mt-6 flex items-center justify-between border-t border-border pt-4">
          <span className="text-sm text-muted">Appearance</span>
          <ThemeToggle />
        </div>
      </Sheet>
    </>
  );
}

export function Splash() {
  return (
    <div className="flex min-h-dvh items-center justify-center" role="status" aria-label="Loading">
      <span className="flex items-center gap-3 animate-pulse">
        <BrandMark className="size-8" />
        <span className="font-display text-2xl text-subtle">{BRAND_NAME}</span>
      </span>
    </div>
  );
}

/** Authenticated layout: guards, realtime, navigation. */
export function AppShell() {
  const { session, loading } = useAuth();
  const { profile, profiles, loading: profilesLoading, error } = useProfileContext();
  const nav = useNav(profile?.profile_code ?? null);
  useRealtimeInvalidation(profile?.profile_code ?? null);

  if (loading) return <Splash />;
  if (!session) return <Navigate to="/signin" />;
  if (profilesLoading) return <Splash />;
  if (error) return <ErrorState error={error} title="Couldn't load your ledgers" className="min-h-dvh" />;
  if (profiles.length === 0 || !profile) return <Navigate to="/welcome" />;

  return (
    <div className="flex min-h-dvh">
      <Sidebar nav={nav} />
      <div className="min-w-0 flex-1">
        <MobileNav nav={nav} />
        <main key={profile.profile_code} className="mx-auto w-full max-w-[1240px] pt-6 pr-[max(var(--space-gutter),env(safe-area-inset-right))] pb-[calc(7rem+env(safe-area-inset-bottom))] pl-[max(var(--space-gutter),env(safe-area-inset-left))] md:pt-10 md:pr-[max(var(--space-gutter-lg),env(safe-area-inset-right))] md:pl-[max(var(--space-gutter-lg),env(safe-area-inset-left))] lg:pb-16">
          <Outlet />
        </main>
      </div>
    </div>
  );
}
