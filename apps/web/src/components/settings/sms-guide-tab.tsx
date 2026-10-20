import { useMemo, useState, type ReactNode } from "react";
import { ArrowUpRight, Check, ChevronRight, Clock, Copy, Info, LifeBuoy, Lock, MessageSquareText, Smartphone, Sparkles } from "lucide-react";
import { Card, CardHeader } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { useToast } from "@/components/ui/toast";
import { BRAND_NAME } from "@/lib/brand";
import { cn } from "@/lib/cn";
import { qrPath } from "@/lib/qr";
import {
  ACCOUNT_AUTOMATION,
  AUTOMATION_STEPS,
  BANNERS,
  PREREQUISITES,
  PRIVACY_NOTE,
  SHORTCUTS_URL,
  TEST_STEPS,
  TROUBLESHOOTING,
  WHY_MANUAL,
  detectPlatform,
  emphasis,
  smsGuideUrl,
  testflightUrl,
  type FieldValue,
  type GuideField,
  type Platform,
} from "@/lib/sms-guide";

const TESTFLIGHT_URL = testflightUrl(import.meta.env.VITE_TESTFLIGHT_URL as string | undefined);

const LINK_BASE = "inline-flex h-10 shrink-0 items-center gap-2 rounded-md px-4 text-sm font-medium whitespace-nowrap transition-colors duration-150";
const LINK_PRIMARY = cn(LINK_BASE, "border border-transparent bg-accent text-accent-ink hover:bg-accent-hover");
const LINK_SECONDARY = cn(LINK_BASE, "border border-border bg-surface text-ink hover:border-border-strong hover:bg-surface-2");

function usePlatform(): Platform {
  return useMemo(() => (typeof navigator === "undefined" ? "desktop" : detectPlatform(navigator.userAgent, navigator.maxTouchPoints)), []);
}

/** Guide copy with `*on-screen names*` in medium weight. */
function Rich({ text }: { text: string }) {
  return (
    <>
      {emphasis(text).map((run, i) =>
        run.strong ? (
          <b key={i} className="font-medium text-ink">
            {run.text}
          </b>
        ) : (
          <span key={i}>{run.text}</span>
        ),
      )}
    </>
  );
}

function CopyButton({ value }: { value: string }) {
  const toast = useToast();
  const [copied, setCopied] = useState(false);
  return (
    <Button
      size="icon-sm"
      variant="ghost"
      aria-label={`Copy “${value}”`}
      onClick={() => {
        void navigator.clipboard.writeText(value).then(
          () => {
            setCopied(true);
            toast({ title: `Copied “${value}”`, tone: "positive" });
            window.setTimeout(() => setCopied(false), 1500);
          },
          () => toast({ title: "Couldn't copy", description: `Type ${value} instead.`, tone: "danger" }),
        );
      }}
    >
      {copied ? <Check className="size-3.5 text-positive" /> : <Copy className="size-3.5" />}
    </Button>
  );
}

function FieldValueView({ value }: { value: FieldValue }) {
  switch (value.kind) {
    case "text":
      return <span className="font-medium text-ink">{value.text}</span>;
    case "placeholder":
      return <span className="text-subtle">{value.text}</span>;
    case "selected":
      return (
        <span className="flex items-center gap-1 text-accent">
          <Check className="size-4" aria-hidden />
          <span className="sr-only">Selected</span>
        </span>
      );
    case "toggle":
      return (
        <span
          role="img"
          aria-label={value.on ? "On" : "Off"}
          className={cn("inline-flex h-5 w-9 items-center rounded-pill p-0.5", value.on ? "bg-positive" : "bg-border-strong")}
        >
          <span className={cn("size-4 rounded-pill bg-surface", value.on && "translate-x-4")} />
        </span>
      );
    case "variable":
      return (
        <span className="inline-flex items-center gap-1 rounded-sm bg-info-soft px-1.5 py-0.5 text-[12px] font-medium text-info">
          <Sparkles className="size-3" aria-hidden />
          {value.variable}
          <ChevronRight className="size-3" aria-label="then" />
          {value.property}
        </span>
      );
  }
}

/** A row of the iPhone screen as it should look after the step. */
function PhoneField({ field }: { field: GuideField }) {
  return (
    <div className="flex min-h-10 items-center justify-between gap-3 rounded-md border border-border bg-surface-2 py-1.5 pr-1.5 pl-3 text-[13px]">
      <span className="text-ink-2">{field.label}</span>
      <span className="flex items-center gap-1.5">
        <FieldValueView value={field.value} />
        {field.copy ? <CopyButton value={field.copy} /> : <span className="w-1.5" aria-hidden />}
      </span>
    </div>
  );
}

function OpenShortcuts({ className }: { className?: string }) {
  return (
    <a href={SHORTCUTS_URL} className={cn(LINK_PRIMARY, className)}>
      <ArrowUpRight className="size-4" aria-hidden /> Open Shortcuts app
    </a>
  );
}

function TestFlightLink() {
  if (!TESTFLIGHT_URL) return null;
  return (
    <a href={TESTFLIGHT_URL} target="_blank" rel="noreferrer" className={LINK_SECONDARY}>
      <Smartphone className="size-4" aria-hidden /> Get the {BRAND_NAME} app (TestFlight)
    </a>
  );
}

function StepNumber({ n }: { n: number }) {
  return (
    <span className="flex size-7 shrink-0 items-center justify-center rounded-pill border border-border-strong bg-surface text-[12px] font-medium text-ink-2 tabular">
      {n}
    </span>
  );
}

function SideCard({ icon, title, children }: { icon: ReactNode; title: string; children: ReactNode }) {
  return (
    <Card className="h-fit">
      <CardHeader
        title={
          <span className="flex items-center gap-2">
            <span className="text-muted [&>svg]:size-4" aria-hidden>
              {icon}
            </span>
            {title}
          </span>
        }
      />
      <div className="px-5 pb-5 text-[13px] text-ink-2">{children}</div>
    </Card>
  );
}

function QrCard() {
  const url = smsGuideUrl(window.location.origin);
  const { size, path } = useMemo(() => qrPath(url), [url]);
  return (
    <SideCard icon={<Smartphone />} title="Open this on your iPhone">
      <p className="text-muted">Point the iPhone camera at the code. The guide opens there, with a button that jumps straight into Shortcuts.</p>
      <div className="qr-code mx-auto mt-4 w-fit rounded-md p-3">
        <svg viewBox={`0 0 ${size} ${size}`} shapeRendering="crispEdges" className="block size-40" role="img" aria-label="QR code that opens this guide">
          <path d={path} fill="currentColor" />
        </svg>
      </div>
      <p className="mt-2 text-center font-mono text-[11px] break-all text-subtle">{url}</p>
    </SideCard>
  );
}

export function SmsGuideTab() {
  const platform = usePlatform();
  const ios = platform === "ios";

  return (
    <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_20rem]">
      <div className="flex min-w-0 flex-col gap-4">
        <Card>
          <CardHeader title="Send bank SMS from your iPhone" />
          <div className="flex flex-col gap-3 px-5 pb-5">
            <p className="text-[13px] text-muted">
              A Shortcuts automation on your iPhone hands each bank alert to the {BRAND_NAME} app, so card spending shows up seconds after you pay, long before the
              statement arrives.
            </p>
            <p className="flex items-start gap-2 text-[13px] text-ink-2">
              <Clock className="mt-0.5 size-4 shrink-0 text-muted" aria-hidden />
              {WHY_MANUAL}
            </p>
            {platform === "android" && (
              <p className="rounded-md bg-info-soft px-3 py-2 text-[13px] text-info">SMS capture needs an iPhone: the {BRAND_NAME} app is iOS only.</p>
            )}
            {(ios || TESTFLIGHT_URL) && (
              <div className="flex flex-wrap gap-2 pt-1">
                {ios && <OpenShortcuts />}
                <TestFlightLink />
              </div>
            )}
          </div>
        </Card>

        <Card>
          <CardHeader eyebrow="Before you start" title="On your iPhone" />
          <ul className="flex flex-col gap-3 px-5 pb-5">
            {PREREQUISITES.map((p) => (
              <li key={p.id} className="flex gap-3">
                <Check className="mt-0.5 size-4 shrink-0 text-accent" aria-hidden />
                <div className="min-w-0">
                  <p className="text-sm font-medium text-ink">{p.title}</p>
                  <p className="mt-0.5 text-[13px] text-muted">
                    <Rich text={p.detail} />
                  </p>
                  {p.testflight && TESTFLIGHT_URL && (
                    <div className="mt-2">
                      <TestFlightLink />
                    </div>
                  )}
                </div>
              </li>
            ))}
          </ul>
        </Card>

        <Card>
          <CardHeader eyebrow="About a minute" title="Create the automation" />
          <ol className="flex flex-col px-5 pb-5">
            {AUTOMATION_STEPS.map((s, i) => (
              <li key={s.id} className="relative flex gap-4 pb-6 last:pb-0">
                {i < AUTOMATION_STEPS.length - 1 && <span aria-hidden className="absolute top-8 bottom-1 left-[13px] w-px bg-border" />}
                <StepNumber n={i + 1} />
                <div className="min-w-0 flex-1 pt-0.5">
                  <p className="text-sm font-medium text-ink">{s.title}</p>
                  <p className="mt-0.5 text-[13px] text-muted">
                    <Rich text={s.detail} />
                  </p>
                  {s.fields && (
                    <div className="mt-2.5 flex max-w-sm flex-col gap-1.5">
                      {s.fields.map((f) => (
                        <PhoneField key={f.label} field={f} />
                      ))}
                    </div>
                  )}
                  {s.opensShortcuts && ios && <OpenShortcuts className="mt-2.5" />}
                </div>
              </li>
            ))}
          </ol>
          <div className="mx-5 mb-5 rounded-md border border-border bg-surface-2 px-4 py-3">
            <p className="text-sm font-medium text-ink">{ACCOUNT_AUTOMATION.title}</p>
            <p className="mt-0.5 text-[13px] text-muted">
              <Rich text={ACCOUNT_AUTOMATION.detail} />
            </p>
          </div>
        </Card>

        <Card>
          <CardHeader eyebrow="Check it works" title="Test it" />
          <ul className="flex flex-col gap-3 px-5 pb-5">
            {TEST_STEPS.map((t) => (
              <li key={t.id} className="flex gap-3 text-[13px] text-ink-2">
                <MessageSquareText className="mt-0.5 size-4 shrink-0 text-muted" aria-hidden />
                <p>
                  <Rich text={t.detail} />
                </p>
              </li>
            ))}
          </ul>
        </Card>
      </div>

      <div className="flex min-w-0 flex-col gap-4">
        {platform === "desktop" && <QrCard />}

        <SideCard icon={<Info />} title="What the banner means">
          <dl className="flex flex-col gap-2.5">
            {BANNERS.map((b) => (
              <div key={b.says}>
                <dt className="font-medium text-ink">{b.says}</dt>
                <dd className="text-muted">{b.means}</dd>
              </div>
            ))}
          </dl>
        </SideCard>

        <SideCard icon={<LifeBuoy />} title="Troubleshooting">
          <dl className="flex flex-col gap-2.5">
            {TROUBLESHOOTING.map((t) => (
              <div key={t.problem}>
                <dt className="font-medium text-ink">{t.problem}</dt>
                <dd className="text-muted">{t.fix}</dd>
              </div>
            ))}
          </dl>
        </SideCard>

        <SideCard icon={<Lock />} title="Privacy">
          <p>{PRIVACY_NOTE}</p>
          <p className="mt-2 text-muted">
            Messages {BRAND_NAME} can't read land in <b className="font-medium text-ink">Review</b>, so nothing is lost.
          </p>
        </SideCard>
      </div>
    </div>
  );
}
