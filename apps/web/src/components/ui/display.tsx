import type { HTMLAttributes, ReactNode } from "react";
import { cn } from "@/lib/cn";

export type Tone = "neutral" | "accent" | "positive" | "warn" | "danger" | "info";

const TONES: Record<Tone, string> = {
  neutral: "bg-surface-2 text-ink-2 border-border",
  accent: "bg-accent-soft text-accent border-transparent",
  positive: "bg-positive-soft text-positive border-transparent",
  warn: "bg-warn-soft text-warn border-transparent",
  danger: "bg-danger-soft text-danger border-transparent",
  info: "bg-info-soft text-info border-transparent",
};

export function Badge({ tone = "neutral", className, children, ...rest }: HTMLAttributes<HTMLSpanElement> & { tone?: Tone }) {
  return (
    <span
      className={cn("inline-flex h-5 items-center gap-1 rounded-pill border px-2 text-[11px] font-medium whitespace-nowrap", TONES[tone], className)}
      {...rest}
    >
      {children}
    </span>
  );
}

export function Card({ className, ...rest }: HTMLAttributes<HTMLElement>) {
  return <section className={cn("rounded-lg border border-border bg-surface", className)} {...rest} />;
}

export function CardHeader({ title, eyebrow, action, className }: { title: ReactNode; eyebrow?: ReactNode; action?: ReactNode; className?: string }) {
  return (
    <header className={cn("flex items-start justify-between gap-3 px-5 pt-4 pb-3", className)}>
      <div className="min-w-0">
        {eyebrow && <p className="mb-0.5 text-[11px] font-medium tracking-[0.08em] text-subtle uppercase">{eyebrow}</p>}
        <h2 className="text-[15px] font-semibold text-ink">{title}</h2>
      </div>
      {action && <div className="shrink-0">{action}</div>}
    </header>
  );
}

export function Skeleton({ className }: { className?: string }) {
  return <div aria-hidden className={cn("animate-pulse rounded-sm bg-surface-2", className)} />;
}

export function PageHeader({ title, eyebrow, description, actions }: { title: ReactNode; eyebrow?: ReactNode; description?: ReactNode; actions?: ReactNode }) {
  return (
    <header className="mb-6 flex flex-wrap items-end justify-between gap-4">
      <div className="min-w-0">
        {eyebrow && <p className="mb-1 text-[11px] font-medium tracking-[0.1em] text-subtle uppercase">{eyebrow}</p>}
        <h1 className="font-display text-[28px] leading-tight font-normal tracking-[-0.01em] text-ink md:text-[32px]">{title}</h1>
        {description && <p className="mt-1.5 max-w-2xl text-sm text-muted">{description}</p>}
      </div>
      {actions && <div className="flex flex-wrap items-center gap-2">{actions}</div>}
    </header>
  );
}

/** Coloured dot for a category colour token. */
export function Dot({ token, className }: { token: string | null | undefined; className?: string }) {
  const v = token && /^cat-\d+$/.test(token) ? token : "uncategorized";
  return <span aria-hidden className={cn("inline-block size-2 shrink-0 rounded-pill", className)} style={{ background: `var(--chart-${v})` }} />;
}

/**
 * A horizontal meter. `marker` draws a tick at a 0–1 position, e.g. a budget's "expected by today"
 * (WEB-38); its `label` is a tooltip, so say the same thing in text nearby or in `label`. `label`
 * is required: a meter needs an accessible name (WEB-52).
 */
export function Meter({
  value,
  tone = "accent",
  className,
  label,
  marker,
}: {
  value: number | null;
  tone?: "accent" | "positive" | "warn" | "danger";
  className?: string;
  label: string;
  marker?: { at: number; label: string } | null;
}) {
  const pct = Math.max(0, Math.min(1, value ?? 0)) * 100;
  const color = { accent: "bg-accent", positive: "bg-positive", warn: "bg-warn", danger: "bg-danger" }[tone];
  const bar = (
    <div
      role="meter"
      aria-label={label}
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={Math.round(pct)}
      className={cn("w-full overflow-hidden rounded-pill bg-surface-3", marker ? "h-full" : "h-1.5", !marker && className)}
    >
      <div className={cn("h-full rounded-pill transition-[width] duration-500", color)} style={{ width: `${pct}%` }} />
    </div>
  );
  if (!marker) return bar;
  const at = Math.max(0, Math.min(1, marker.at)) * 100;
  return (
    <div className={cn("relative h-1.5 w-full", className)}>
      {bar}
      <span
        aria-hidden
        title={marker.label}
        className="absolute -top-1 -bottom-1 w-0.5 -translate-x-1/2 rounded-pill bg-ink"
        style={{ left: `${at}%` }}
      />
    </div>
  );
}

export function Kbd({ children }: { children: ReactNode }) {
  return <kbd className="rounded-[4px] border border-border bg-surface-2 px-1 font-mono text-[11px] text-muted">{children}</kbd>;
}
