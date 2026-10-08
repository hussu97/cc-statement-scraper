import type { ReactNode } from "react";
import { Download, Info } from "lucide-react";
import { Card, CardHeader } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { Tooltip } from "@/components/ui/primitives";

const STEPS: { title: string; body: ReactNode }[] = [
  { title: "Install Ledger on your iPhone", body: "Sign in with the same account you use here, and pick this ledger." },
  { title: "Open Shortcuts → Automation", body: "Tap + (or New Automation) and choose Message." },
  {
    title: "Pick the trigger",
    body: (
      <>
        Set <b className="font-medium text-ink">Message contains</b> to a word your bank always uses, like <Code>AED</Code> or <Code>card ending</Code>. Under{" "}
        <b className="font-medium text-ink">Sender</b>, add your banks' SMS senders.
      </>
    ),
  },
  { title: "Choose Run Immediately", body: "Turn off Notify When Run if you don't want a banner each time." },
  {
    title: "Add the “Log bank SMS” action",
    body: (
      <>
        Search for Ledger, add <b className="font-medium text-ink">Log bank SMS</b>, and pass <b className="font-medium text-ink">Shortcut Input</b> → Content as the
        message and → Sender as the sender.
      </>
    ),
  },
  { title: "Save and test", body: "Next time you pay by card, the transaction appears in Activity within seconds." },
];

function Code({ children }: { children: ReactNode }) {
  return <code className="rounded-[4px] bg-surface-2 px-1 py-0.5 font-mono text-[12px] text-ink">{children}</code>;
}

export function SmsGuideTab() {
  return (
    <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_20rem]">
      <Card>
        <CardHeader title="Send bank SMS from your iPhone" />
        <p className="-mt-1 px-5 text-[13px] text-muted">
          An iOS Shortcuts automation passes each bank message to the Ledger app, so card spending shows up before the statement arrives.
        </p>
        <ol className="flex flex-col gap-0 px-5 py-4">
          {STEPS.map((s, i) => (
            <li key={s.title} className="relative flex gap-4 pb-5 last:pb-0">
              {i < STEPS.length - 1 && <span aria-hidden className="absolute top-8 bottom-1 left-[13px] w-px bg-border" />}
              <span className="flex size-7 shrink-0 items-center justify-center rounded-pill border border-border-strong bg-surface text-[12px] font-medium text-ink-2 tabular">
                {i + 1}
              </span>
              <div className="min-w-0 pt-0.5">
                <p className="text-sm font-medium text-ink">{s.title}</p>
                <p className="mt-0.5 text-[13px] text-muted">{s.body}</p>
              </div>
            </li>
          ))}
        </ol>
        <div className="flex flex-wrap items-center gap-3 border-t border-border px-5 py-4">
          <Tooltip content="Link coming soon">
            <span tabIndex={0}>
              <Button variant="secondary" icon={<Download className="size-4" />} disabled>
                Get the shortcut
              </Button>
            </span>
          </Tooltip>
          <span className="text-[12px] text-subtle">Link coming soon. Until then, build it with the steps above.</span>
        </div>
      </Card>

      <Card className="h-fit">
        <CardHeader
          title={
            <span className="flex items-center gap-2">
              <Info className="size-4 text-muted" aria-hidden /> Good to know
            </span>
          }
        />
        <ul className="flex list-disc flex-col gap-2.5 pr-5 pb-5 pl-9 text-[13px] text-ink-2 marker:text-subtle">
          <li>One-time passwords are dropped on your phone and never leave it.</li>
          <li>Debit-card and account messages are stored as ignored; only credit-card spending becomes transactions.</li>
          <li>Shortcuts matches one phrase per automation. Add a second automation for each extra keyword.</li>
          <li>Senders are the names your bank texts from, as shown in Messages.</li>
          <li>
            Messages Ledger can't read land in <b className="font-medium text-ink">Review</b> so nothing is lost.
          </li>
        </ul>
      </Card>
    </div>
  );
}
