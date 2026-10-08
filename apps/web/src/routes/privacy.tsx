import type { ReactNode } from "react";
import { Link } from "@tanstack/react-router";
import { ArrowLeft } from "lucide-react";
import { ThemeToggle } from "@/components/shell";
import { BrandLockup } from "@/components/brand/brand";
import { useAuth } from "@/data/auth";
import { PRIVACY_CONTACT_EMAIL, PRIVACY_LAST_UPDATED } from "@/lib/public-routes";

function Section({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="mt-10">
      <h2 className="font-display text-[22px] leading-snug tracking-[-0.01em] text-ink">{title}</h2>
      <div className="mt-3 flex flex-col gap-3 text-[15px] leading-relaxed text-ink-2">{children}</div>
    </section>
  );
}

function List({ children }: { children: ReactNode }) {
  return <ul className="ml-5 flex list-disc flex-col gap-2 marker:text-subtle">{children}</ul>;
}

const mail = (
  <a href={`mailto:${PRIVACY_CONTACT_EMAIL}`} className="text-accent underline underline-offset-2 hover:text-accent-hover">
    {PRIVACY_CONTACT_EMAIL}
  </a>
);

/** Public privacy policy. Rendered outside the authenticated AppShell. */
export function PrivacyPage() {
  const { session } = useAuth();
  return (
    <div className="flex min-h-dvh flex-col bg-bg">
      <div className="flex items-center justify-between gap-3 px-gutter pt-[max(1rem,env(safe-area-inset-top))] pb-4 md:px-gutter-lg">
        <BrandLockup to={session ? "/" : "/signin"} />
        <ThemeToggle />
      </div>
      <main className="flex flex-1 justify-center px-gutter pt-[6vh] pb-20">
        <article className="w-full max-w-[68ch] animate-rise">
          <Link to={session ? "/settings" : "/signin"} className="tap mb-8 inline-flex items-center gap-1.5 text-sm text-muted hover:text-ink">
            <ArrowLeft className="size-4" /> {session ? "Back to settings" : "Back to sign in"}
          </Link>
          <p className="mb-2 text-[11px] font-medium tracking-[0.1em] text-subtle uppercase">Bank Ledger</p>
          <h1 className="font-display text-[34px] leading-[1.1] tracking-[-0.015em] text-ink">Privacy policy</h1>
          <p className="mt-3 text-sm text-muted">
            Last updated <time dateTime={PRIVACY_LAST_UPDATED}>8 October 2026</time>
          </p>

          <div className="mt-6 text-[15px] leading-relaxed text-ink-2">
            <p>
              Bank Ledger is a personal app for tracking credit-card spending, operated by Hussain Abbasi. It is available to invited users only. This page
              explains what data it holds, where that data goes, and how to have it removed. Questions: {mail}.
            </p>
          </div>

          <Section title="What we collect">
            <List>
              <li>Your account email address, used to sign you in.</li>
              <li>Credit-card statement PDFs that you upload or forward by email.</li>
              <li>
                Bank SMS alerts that you choose to send through an iOS Shortcuts automation. One-time passwords are filtered out on your phone and are never
                sent.
              </li>
              <li>Transactions, categories, budgets and notes derived from the above or entered by you.</li>
            </List>
          </Section>

          <Section title="Where it is stored and processed">
            <List>
              <li>
                <strong className="font-medium text-ink">Supabase</strong>: database, authentication and file storage.
              </li>
              <li>
                <strong className="font-medium text-ink">Google Cloud Run</strong>: parses statements. No data is retained there.
              </li>
              <li>
                <strong className="font-medium text-ink">Vercel</strong>: hosts this web app.
              </li>
              <li>
                <strong className="font-medium text-ink">Sentry</strong>: crash and error diagnostics, with personal data scrubbed. No SMS text and no
                statement contents are sent.
              </li>
              <li>
                <strong className="font-medium text-ink">Anthropic Claude API</strong>: receives merchant names and, for alert formats the app doesn't
                recognise, the SMS text, to suggest categories and parsing templates. Statements and amounts are never sent. Under Anthropic's API terms this
                data is not used for training.
              </li>
            </List>
          </Section>

          <Section title="What we don't do">
            <p>
              No advertising and no tracking or analytics SDKs. Your data is never sold, and it is not shared with anyone beyond the processors listed above.
            </p>
          </Section>

          <Section title="Retention and deletion">
            <p>
              Data is kept until you ask for it to be deleted. To request an export or deletion, email {mail}. Deletion removes your ledger data within 30
              days.
            </p>
          </Section>

          <Section title="Security">
            <List>
              <li>All traffic is encrypted in transit.</li>
              <li>Row-level security in the database isolates each ledger, so members only see ledgers they belong to.</li>
              <li>Statement passwords are stored encrypted in Supabase Vault.</li>
            </List>
          </Section>

          <Section title="Children">
            <p>Bank Ledger is not intended for anyone under 18.</p>
          </Section>

          <Section title="Changes">
            <p>
              When this policy changes, the date at the top of this page is updated.
            </p>
          </Section>
        </article>
      </main>
    </div>
  );
}
