import { Link } from "@tanstack/react-router";
import { BRAND_NAME, MARK_GLYPH, MARK_TILE_RX } from "@/lib/brand";
import { cn } from "@/lib/cn";

/** The Bank Ledger mark, drawn in token colours so it follows the theme. */
export function BrandMark({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 32 32" aria-hidden className={cn("size-6 shrink-0", className)}>
      <rect width="32" height="32" rx={MARK_TILE_RX} className="fill-accent" />
      <g className="fill-bg">
        {MARK_GLYPH.map((r) => (
          <rect key={`${r.x}-${r.y}`} x={r.x} y={r.y} width={r.width} height={r.height} rx={r.rx} />
        ))}
      </g>
    </svg>
  );
}

/** Mark + "Bank Ledger". Links to `to` when given. */
export function BrandLockup({ to, className }: { to?: "/" | "/signin"; className?: string }) {
  const body = (
    <>
      <BrandMark />
      <span className="font-display text-[22px] leading-none tracking-[-0.02em] whitespace-nowrap text-ink">{BRAND_NAME}</span>
    </>
  );
  const cls = cn("flex items-center gap-2.5", className);
  return to ? (
    <Link to={to} className={cls} aria-label={`${BRAND_NAME} home`}>
      {body}
    </Link>
  ) : (
    <span className={cls}>{body}</span>
  );
}
