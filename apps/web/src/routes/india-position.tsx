import { lazy, Suspense, useMemo, type ReactNode } from "react";
import { Link } from "@tanstack/react-router";
import { ArrowLeft } from "lucide-react";
import { indiaCoinPositionRoute, indiaKitePositionRoute } from "@/router";
import { useActiveProfile } from "@/data/profile";
import { useIndiaOverview } from "@/data/india";
import { useBrokerPosition } from "@/data/broker";
import { INDIA_TAB, indiaAccountFor, type IndiaSegment } from "@/lib/india";
import { assetLabel, positionLine, positionPoints, priceLine, trimPrice, type PositionDetail } from "@/lib/broker-detail";
import { formatUnits } from "@/lib/investments";
import { formatPct, signTone } from "@/lib/holdings";
import { formatTotal } from "@/lib/money";
import { formatDate } from "@/lib/dates";
import { Card, CardHeader, PageHeader } from "@/components/ui/display";
import { EmptyState, ErrorState, LoadingBlock } from "@/components/ui/states";
import { SipsCard } from "@/components/india/india-portfolio";
import { TONE_TEXT } from "@/components/wealth/broker-portfolio";
import { NoIndia } from "./india";

// The chart library loads after the page renders (as on Overview, WEB-53).
const PortfolioChart = lazy(() => import("@/components/wealth/portfolio-chart").then((m) => ({ default: m.PortfolioChart })));

/** India → Kite → a position: what it is, its worth against its cost over time, today's move. */
export function IndiaKitePositionPage() {
  const { isin } = indiaKitePositionRoute.useParams();
  return <IndiaPositionPage segment="kite" isin={isin} />;
}

/** India → Coin → a fund, as a Kite position, with its SIPs. */
export function IndiaCoinPositionPage() {
  const { isin } = indiaCoinPositionRoute.useParams();
  return <IndiaPositionPage segment="coin" isin={isin} />;
}

function Back({ segment }: { segment: IndiaSegment }) {
  return (
    <Link to={INDIA_TAB[segment].path} className="tap inline-flex items-center gap-1 self-start text-[13px] text-muted hover:text-ink">
      <ArrowLeft className="size-3.5" aria-hidden /> Zerodha {INDIA_TAB[segment].label}
    </Link>
  );
}

function IndiaPositionPage({ segment, isin }: { segment: IndiaSegment; isin: string }) {
  const { profile_code: profileCode } = useActiveProfile();
  const overview = useIndiaOverview(profileCode);
  const o = overview.data;
  const account = o?.available ? indiaAccountFor(o.accounts, segment) : null;

  return (
    <div className="animate-fade-in flex flex-col gap-6">
      <Back segment={segment} />
      {overview.isLoading ? (
        <Card>
          <LoadingBlock className="h-72" />
        </Card>
      ) : overview.isError || !o ? (
        <Card>
          <ErrorState title="Couldn't load India" error={overview.error} onRetry={() => void overview.refetch()} />
        </Card>
      ) : !o.available || !account ? (
        <NoIndia />
      ) : (
        <Position profileCode={profileCode} accountCode={account.account_code} isin={isin} segment={segment} />
      )}
    </div>
  );
}

function Position({ profileCode, accountCode, isin, segment }: { profileCode: string; accountCode: string; isin: string; segment: IndiaSegment }) {
  const q = useBrokerPosition(profileCode, accountCode, isin);
  if (q.isLoading)
    return (
      <Card>
        <LoadingBlock className="h-72" />
      </Card>
    );
  if (q.isError)
    return (
      <Card>
        <ErrorState title="Couldn't load this position" error={q.error} onRetry={() => void q.refetch()} />
      </Card>
    );
  const d = q.data;
  if (!d)
    return (
      <Card>
        <EmptyState title="Not in this account">Zerodha {INDIA_TAB[segment].label} has never reported a holding with ISIN {isin}.</EmptyState>
      </Card>
    );
  return <PositionView d={d} segment={segment} />;
}

function Figure({ label, children, sub }: { label: string; children: ReactNode; sub?: ReactNode }) {
  return (
    <div className="min-w-0">
      <dt className="text-[12px] text-subtle">{label}</dt>
      <dd className="tabular mt-0.5 text-[19px] leading-tight font-medium whitespace-nowrap text-ink sm:text-[24px]">{children}</dd>
      {sub && <dd className="tabular mt-0.5 text-[12px] text-muted">{sub}</dd>}
    </div>
  );
}

function Fact({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="flex items-baseline justify-between gap-4 px-5 py-2.5 text-[13px]">
      <dt className="text-muted">{label}</dt>
      <dd className="tabular min-w-0 truncate text-right text-ink">{children}</dd>
    </div>
  );
}

function PositionView({ d, segment }: { d: PositionDetail; segment: IndiaSegment }) {
  const p = d.position;
  const c = d.currency;
  const points = useMemo(() => positionPoints(d.series), [d.series]);
  const kind = assetLabel(p?.asset_class);
  return (
    <>
      <PageHeader
        eyebrow={[`Zerodha ${INDIA_TAB[segment].label}`, kind].filter(Boolean).join(" · ")}
        title={p?.name ?? d.name}
        description={p ? positionLine(p) : d.isin}
      />
      {!p ? (
        <Card>
          <EmptyState title="No longer held">
            Zerodha {INDIA_TAB[segment].label} last reported it on {formatDate(d.last_marked_on)}. What it made is on the account's Sold tab.
          </EmptyState>
        </Card>
      ) : (
        <Card>
          <dl className="grid grid-cols-2 gap-x-4 gap-y-4 px-5 py-5 sm:gap-x-6 xl:grid-cols-4">
            <Figure label="Value" sub={priceLine(p, c)}>
              {formatTotal(p.value, { currency: c })}
            </Figure>
            <Figure label="P&L" sub={p.cost && `on ${formatTotal(p.cost, { currency: c })} invested`}>
              <span className={TONE_TEXT[signTone(p.profit)]}>{formatTotal(p.profit, { currency: c, signed: true })}</span>
              {p.return_pct && <span className={`ml-1.5 text-[14px] ${TONE_TEXT[signTone(p.profit)]}`}>{formatPct(p.return_pct, { signed: true })}</span>}
            </Figure>
            <Figure label="Today" sub={formatPct(p.day_change_pct, { signed: true }) ?? (p.asset_class === "fund" ? "After the next NAV" : undefined)}>
              <span className={TONE_TEXT[signTone(p.day_change)]}>{formatTotal(p.day_change, { currency: c, signed: true })}</span>
            </Figure>
            <Figure label="Share of account">{formatPct(p.weight_pct) ?? "—"}</Figure>
          </dl>
        </Card>
      )}
      <Card>
        <CardHeader title="Worth against cost" />
        <div className="px-3 pb-4 md:px-4">
          {points.length < 2 ? (
            <EmptyState title="No history yet" className="h-44">
              The line starts after the second day this holding is synced.
            </EmptyState>
          ) : (
            <Suspense fallback={<LoadingBlock className="h-56" />}>
              <PortfolioChart points={points} currency={c} basis="cost" />
            </Suspense>
          )}
        </div>
      </Card>
      {p && (
        <Card>
          <CardHeader title="Details" />
          <dl className="divide-y divide-border border-t border-border">
            <Fact label="Units">{formatUnits(p.quantity)}</Fact>
            <Fact label="Average cost">{p.cost_price ? `${c} ${trimPrice(p.cost_price)}` : "—"}</Fact>
            <Fact label={p.asset_class === "fund" ? "NAV" : "Last price"}>{priceLine(p, c)}</Fact>
            {p.prev_price && <Fact label={p.asset_class === "fund" ? "Previous NAV" : "Previous close"}>{`${c} ${trimPrice(p.prev_price)}`}</Fact>}
            {p.symbol && p.symbol !== p.isin && <Fact label="Symbol">{p.exchange ? `${p.symbol} · ${p.exchange}` : p.symbol}</Fact>}
            {p.category && <Fact label="Scheme type">{p.category}</Fact>}
            {p.issuer && <Fact label="Fund house">{p.issuer}</Fact>}
            {p.folio && <Fact label="Folio">{p.folio}</Fact>}
            <Fact label="ISIN">{d.isin}</Fact>
            <Fact label="Last synced">{formatDate(d.last_marked_on)}</Fact>
          </dl>
        </Card>
      )}
      <SipsCard sips={d.sips} />
    </>
  );
}
