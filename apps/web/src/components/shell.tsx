import { useEffect, useState, type ReactNode } from "react";
import { Link, Navigate, Outlet, useLocation, useNavigate, useRouterState } from "@tanstack/react-router";
import {
  ArrowLeftRight,
  ChartColumnBig,
  ChevronsUpDown,
  Coins,
  CreditCard,
  Inbox,
  Landmark,
  LayoutGrid,
  LogOut,
  Menu as MenuIcon,
  Plus,
  ReceiptText,
  Settings2,
  Shapes,
  Target,
  Check,
  Wallet,
} from "lucide-react";
import { cn } from "@/lib/cn";
import { formatBadgeCount } from "@/lib/money";
import { signInSearch } from "@/lib/redirect";
import { useAuth, signOut } from "@/data/auth";
import { memberProfiles, useProfileContext, type ProfileSummary } from "@/data/profile";
import { useRealtimeInvalidation } from "@/data/realtime";
import { useOpenReviewCount } from "@/data/reviews";
import { Menu, MenuContent, MenuItem, MenuLabel, MenuSeparator, MenuTrigger, Segmented, TooltipProvider } from "./ui/primitives";
import { APP_MODES, MODE_INFO, modeOfPath, readRememberedMode, rememberMode, resolveMode, type AppMode } from "@/lib/mode";
import { Toaster } from "./ui/toast";
import { Sheet } from "./ui/dialog";
import { ErrorState } from "./ui/states";
import { BrandLockup } from "./brand/brand";
import { Splash, ThemeToggle } from "./chrome";

interface NavItem {
  to: string;
  label: string;
  icon: ReactNode;
  badge?: number;
}

/** Each mode's own screens, in sidebar order. Goals join Wealth later. */
const MODE_NAV: Record<AppMode, NavItem[]> = {
  spending: [
    { to: "/", label: "Overview", icon: <LayoutGrid /> },
    { to: "/activity", label: "Activity", icon: <ReceiptText /> },
    { to: "/insights", label: "Insights", icon: <ChartColumnBig /> },
    { to: "/budgets", label: "Budgets", icon: <Target /> },
    { to: "/cards", label: "Cards & statements", icon: <CreditCard /> },
  ],
  wealth: [
    { to: "/wealth", label: "Overview", icon: <LayoutGrid /> },
    { to: "/wealth/accounts", label: "Accounts", icon: <Landmark /> },
    { to: "/wealth/investments", label: "Investments", icon: <Coins /> },
    { to: "/wealth/cash-flow", label: "Cash flow", icon: <ArrowLeftRight /> },
  ],
};

/** Each mode's phone tabs (the rest go in More). Review, the daily action surface, is always one. */
const MOBILE_TABS: Record<AppMode, string[]> = {
  spending: ["/", "/activity", "/insights", "/review"],
  wealth: ["/wealth", "/wealth/accounts", "/wealth/investments", "/review"],
};

interface Nav {
  mode: AppMode;
  /** The mode's own screens. */
  primary: NavItem[];
  /** Review, Rules and Settings: in both modes. */
  shared: NavItem[];
  setMode: (m: AppMode) => void;
}

/**
 * The mode comes from the path (/wealth/* is Wealth); a shared screen keeps the last mode,
 * remembered across visits (localStorage, wrapped). Switching goes to that mode's home.
 */
function useNav(profileCode: string | null): Nav {
  const reviews = useOpenReviewCount(profileCode);
  const open = profileCode ? (reviews.data ?? 0) : 0;
  const path = useRouterState({ select: (s) => s.location.pathname });
  const navigate = useNavigate();
  const [remembered, setRemembered] = useState<AppMode | null>(readRememberedMode);
  // A mode's own screen makes it the remembered one (adjusting state while rendering, not in an effect).
  const fromPath = modeOfPath(path);
  if (fromPath && fromPath !== remembered) setRemembered(fromPath);
  const mode = resolveMode(path, remembered);
  useEffect(() => rememberMode(mode), [mode]);
  return {
    mode,
    primary: MODE_NAV[mode],
    shared: [
      { to: "/review", label: "Review", icon: <Inbox />, badge: open || undefined },
      { to: "/rules", label: "Rules", icon: <Shapes /> },
      { to: "/settings", label: "Settings", icon: <Settings2 /> },
    ],
    setMode: (m) => {
      setRemembered(m);
      void navigate({ to: MODE_INFO[m].home });
    },
  };
}

/** A mode's home and Overview match only exactly; every other entry also owns its sub-paths. */
const EXACT = new Set(["/", "/wealth"]);

function useIsActive() {
  const path = useRouterState({ select: (s) => s.location.pathname });
  // A statement page belongs to "Cards & statements".
  return (to: string) => (EXACT.has(to) ? path === to : path === to || path.startsWith(`${to}/`) || (to === "/cards" && path.startsWith("/statements/")));
}

const MODE_ICON: Record<AppMode, ReactNode> = { spending: <Wallet />, wealth: <Landmark /> };

/** The Spending / Wealth dropdown at the top of the sidebar (and in the phone header). */
function ModeSwitcher({ nav, compact }: { nav: Nav; compact?: boolean }) {
  const info = MODE_INFO[nav.mode];
  return (
    <Menu>
      <MenuTrigger asChild>
        <button
          type="button"
          aria-label={`Mode: ${info.label}. Switch mode`}
          className={cn(
            "flex min-w-0 items-center gap-2 rounded-md border border-border bg-surface text-left transition-colors hover:border-border-strong [&_svg]:size-4",
            compact ? "h-9 px-2.5" : "w-full px-2.5 py-2",
          )}
        >
          <span className="text-accent">{MODE_ICON[nav.mode]}</span>
          <span className="min-w-0 flex-1">
            <span className="block truncate text-[13px] font-medium text-ink">{info.label}</span>
            {!compact && <span className="block truncate text-[11px] text-subtle">{info.hint}</span>}
          </span>
          <ChevronsUpDown className="size-3.5 shrink-0 text-subtle" aria-hidden />
        </button>
      </MenuTrigger>
      <MenuContent align="start" className="w-60">
        <MenuLabel>Mode</MenuLabel>
        {APP_MODES.map((m) => (
          <MenuItem key={m} onSelect={() => nav.setMode(m)}>
            <span className="text-subtle [&_svg]:size-4">{MODE_ICON[m]}</span>
            <span className="min-w-0 flex-1">
              <span className="block text-[13px] text-ink">{MODE_INFO[m].label}</span>
              <span className="block text-[11px] text-subtle">{MODE_INFO[m].hint}</span>
            </span>
            {m === nav.mode && <Check className="size-3.5 text-accent" />}
          </MenuItem>
        ))}
      </MenuContent>
    </Menu>
  );
}

function profileRoleLabel(p: ProfileSummary | null): string {
  if (!p) return "";
  if (!p.isMember) return "View only";
  return p.role === "owner" ? "Owner" : "Viewer";
}

function ProfileSwitcher({ compact }: { compact?: boolean }) {
  const { profile, profiles, setActive } = useProfileContext();
  const { email } = useAuth();
  const mine = memberProfiles(profiles);
  const others = profiles.filter((p) => !p.isMember);
  const item = (p: ProfileSummary) => (
    <MenuItem key={p.profile_code} onSelect={() => setActive(p.profile_code)}>
      <span className="flex-1 truncate">{p.name}</span>
      {(p.role === "viewer" || !p.isMember) && <span className="text-[11px] text-subtle">{p.isMember ? "viewer" : "view only"}</span>}
      {p.profile_code === profile?.profile_code && <Check className="size-3.5 text-accent" />}
    </MenuItem>
  );
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
            {!compact && <span className="block truncate text-[11px] text-subtle">{profileRoleLabel(profile)}</span>}
          </span>
          <ChevronsUpDown className="size-3.5 shrink-0 text-subtle" aria-hidden />
        </button>
      </MenuTrigger>
      <MenuContent align="start" className="w-60">
        <MenuLabel>Ledgers</MenuLabel>
        {mine.map(item)}
        {others.length > 0 && (
          <>
            <MenuSeparator />
            <MenuLabel>Other ledgers</MenuLabel>
            {others.map(item)}
          </>
        )}
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

function SideLink({ n, active }: { n: NavItem; active: boolean }) {
  return (
    <Link
      to={n.to}
      aria-current={active ? "page" : undefined}
      className={cn(
        "group flex h-9 items-center gap-3 rounded-md px-2.5 text-[13.5px] transition-colors [&_svg]:size-4",
        active ? "bg-surface text-ink shadow-[inset_0_0_0_1px_var(--color-border)]" : "text-muted hover:bg-surface-2 hover:text-ink",
      )}
    >
      <span className={cn(active ? "text-accent" : "text-subtle group-hover:text-ink-2")}>{n.icon}</span>
      <span className="flex-1">{n.label}</span>
      {n.badge ? <span className="tabular rounded-pill bg-accent px-1.5 text-[11px] leading-[18px] font-medium text-accent-ink">{formatBadgeCount(n.badge)}</span> : null}
    </Link>
  );
}

function Sidebar({ nav }: { nav: Nav }) {
  const isActive = useIsActive();
  return (
    <aside className="sticky top-0 hidden h-dvh w-60 shrink-0 flex-col border-r border-border bg-bg px-3 py-5 lg:flex">
      <Wordmark />
      <div className="mt-6">
        <ModeSwitcher nav={nav} />
      </div>
      <nav aria-label="Main" className="mt-4 flex flex-1 flex-col gap-0.5">
        {nav.primary.map((n) => (
          <SideLink key={n.to} n={n} active={isActive(n.to)} />
        ))}
        <div className="my-2 border-t border-border" role="separator" />
        {nav.shared.map((n) => (
          <SideLink key={n.to} n={n} active={isActive(n.to)} />
        ))}
      </nav>
      <div className="flex flex-col gap-3 border-t border-border pt-3">
        <ThemeToggle className="self-start" />
        <ProfileSwitcher />
      </div>
    </aside>
  );
}

function MobileNav({ nav }: { nav: Nav }) {
  const isActive = useIsActive();
  const [more, setMore] = useState(false);
  const all = [...nav.primary, ...nav.shared];
  const tabPaths = MOBILE_TABS[nav.mode];
  const tabs = tabPaths.map((to) => all.find((n) => n.to === to)).filter((n): n is NavItem => !!n);
  const rest = all.filter((n) => !tabPaths.includes(n.to));
  const restBadge = rest.reduce((s, n) => s + (n.badge ?? 0), 0);
  const moreActive = rest.some((n) => isActive(n.to));
  return (
    <>
      <header className="sticky top-0 z-30 flex h-[calc(3.5rem+env(safe-area-inset-top))] items-center justify-between gap-2 border-b border-border bg-bg/90 pt-[env(safe-area-inset-top)] pr-[max(1rem,env(safe-area-inset-right))] pl-[max(1rem,env(safe-area-inset-left))] backdrop-blur lg:hidden">
        <BrandLockup to="/" className="shrink-0 [&>span:last-child]:hidden sm:[&>span:last-child]:inline" />
        <div className="flex min-w-0 flex-1 items-center justify-end gap-2">
          <ModeSwitcher nav={nav} compact />
          <div className="w-36 min-w-0 shrink sm:w-48">
            <ProfileSwitcher compact />
          </div>
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
        <div className="mb-4 flex items-center justify-between gap-3 border-b border-border pb-4">
          <span className="text-sm text-muted">Mode</span>
          <Segmented
            ariaLabel="Mode"
            value={nav.mode}
            onChange={(m) => {
              setMore(false);
              nav.setMode(m);
            }}
            options={APP_MODES.map((m) => ({ value: m, label: MODE_INFO[m].label }))}
          />
        </div>
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

/**
 * To /signin, keeping the deep link so sign-in can send you back (WEB-39). The
 * link is read once: the shell stays mounted while the navigation is pending,
 * and re-reading the location then would see /signin and drop the redirect.
 */
function ToSignIn() {
  const href = useLocation({ select: (l) => l.href });
  const [from] = useState(href);
  return <Navigate to="/signin" search={signInSearch(from)} replace />;
}

/** Main content's id: the skip link's target. */
const MAIN_ID = "main";

/**
 * "Skip to content": the first focusable element, hidden until focused (WEB-52). It moves
 * focus itself rather than following `#main`, so the router never sees a hash change.
 */
function SkipLink() {
  return (
    <a
      href={`#${MAIN_ID}`}
      onClick={(e) => {
        e.preventDefault();
        document.getElementById(MAIN_ID)?.focus();
      }}
      className="sr-only focus:not-sr-only focus:fixed focus:top-3 focus:left-3 focus:z-50 focus:rounded-md focus:border focus:border-border focus:bg-surface focus:px-3 focus:py-2 focus:text-sm focus:font-medium focus:text-ink focus:shadow-[0_8px_24px_-12px_var(--color-border-strong)]"
    >
      Skip to content
    </a>
  );
}

/**
 * Authenticated layout: guards, realtime, navigation. `children` replaces the route outlet,
 * for content that isn't a route of its own (the signed-in 404).
 */
export function AppShell({ children }: { children?: ReactNode }) {
  const { session, loading } = useAuth();
  const { profile, profiles, loading: profilesLoading, error } = useProfileContext();
  const nav = useNav(profile?.profile_code ?? null);
  useRealtimeInvalidation(profile?.profile_code ?? null);

  if (loading) return <Splash />;
  if (!session) return <ToSignIn />;
  if (profilesLoading) return <Splash />;
  if (error) return <ErrorState error={error} title="Couldn't load your ledgers" className="min-h-dvh" />;
  // Onboarding is about memberships: a super admin who belongs to no ledger
  // still starts at /welcome even though RLS shows them every ledger.
  if (memberProfiles(profiles).length === 0 || !profile) return <Navigate to="/welcome" />;

  // Toasts and tooltips live only inside the app, so the public pages load no Radix (WEB-11).
  return (
    <TooltipProvider>
      <Toaster>
        <SkipLink />
        <div className="flex min-h-dvh">
          <Sidebar nav={nav} />
          <div className="min-w-0 flex-1">
            <MobileNav nav={nav} />
            <main key={profile.profile_code} id={MAIN_ID} tabIndex={-1} className="mx-auto w-full outline-none max-w-[1240px] pt-6 pr-[max(var(--space-gutter),env(safe-area-inset-right))] pb-[calc(7rem+env(safe-area-inset-bottom))] pl-[max(var(--space-gutter),env(safe-area-inset-left))] md:pt-10 md:pr-[max(var(--space-gutter-lg),env(safe-area-inset-right))] md:pl-[max(var(--space-gutter-lg),env(safe-area-inset-left))] lg:pb-16">
              {children ?? <Outlet />}
            </main>
          </div>
        </div>
      </Toaster>
    </TooltipProvider>
  );
}
