import { useState, type FormEvent, type ReactNode } from "react";
import { Link, Navigate, useNavigate, useSearch } from "@tanstack/react-router";
import { ArrowLeft, Mail, KeyRound } from "lucide-react";
import { signInErrorMessage, signInWithPassword, sendMagicLink, useAuth, verifyEmailCode } from "@/data/auth";
import { profileKeyFromName, useCreateProfile, useProfileContext } from "@/data/profile";
import { errorMessage } from "@/data/api";
import { Button } from "@/components/ui/button";
import { Field, Input } from "@/components/ui/input";
import { Segmented } from "@/components/ui/primitives";
import { Splash, ThemeToggle } from "@/components/shell";

function AuthFrame({ children, footer }: { children: ReactNode; footer?: ReactNode }) {
  return (
    <div className="flex min-h-dvh flex-col bg-bg">
      <div className="flex items-center justify-between px-gutter py-4 md:px-gutter-lg">
        <span className="flex items-baseline gap-1.5">
          <span className="font-display text-[22px] tracking-[-0.02em] text-ink">Bank Ledger</span>
          <span className="size-1.5 translate-y-[-2px] rounded-pill bg-accent" aria-hidden />
        </span>
        <ThemeToggle />
      </div>
      <main className="flex flex-1 items-start justify-center px-gutter pt-[8vh] pb-16">
        <div className="w-full max-w-[400px] animate-rise">{children}</div>
      </main>
      {footer}
    </div>
  );
}

export function SignInPage() {
  const { session, loading } = useAuth();
  const [mode, setMode] = useState<"password" | "link">("password");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [code, setCode] = useState("");
  const [sent, setSent] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (loading) return <Splash />;
  if (session) return <Navigate to="/" />;

  const run = async (fn: () => Promise<void>) => {
    setBusy(true);
    setError(null);
    try {
      await fn();
    } catch (e) {
      setError(signInErrorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  const onPassword = (e: FormEvent) => {
    e.preventDefault();
    void run(() => signInWithPassword(email.trim(), password));
  };
  const onLink = (e: FormEvent) => {
    e.preventDefault();
    if (sent) void run(() => verifyEmailCode(email.trim(), code.trim()));
    else void run(async () => {
      await sendMagicLink(email.trim());
      setSent(true);
    });
  };

  return (
    <AuthFrame
      footer={
        <footer className="px-gutter pb-6 text-center text-[12px] text-subtle">
          <Link to="/privacy" className="underline underline-offset-2 hover:text-ink">
            Privacy policy
          </Link>
        </footer>
      }
    >
      <p className="mb-2 text-[11px] font-medium tracking-[0.1em] text-subtle uppercase">Your card ledger</p>
      <h1 className="font-display text-[34px] leading-[1.1] tracking-[-0.015em] text-ink">Sign in</h1>
      <p className="mt-2 text-sm text-muted">Every purchase from your bank SMS, reconciled against your statements.</p>

      <Segmented
        className="mt-8"
        ariaLabel="Sign-in method"
        value={mode}
        onChange={(m) => {
          setMode(m);
          setError(null);
        }}
        options={[
          { value: "password", label: <span className="flex items-center gap-1.5"><KeyRound className="size-3.5" />Password</span> },
          { value: "link", label: <span className="flex items-center gap-1.5"><Mail className="size-3.5" />Email link</span> },
        ]}
      />

      {mode === "password" ? (
        <form onSubmit={onPassword} className="mt-6 flex flex-col gap-4" noValidate>
          <Field label="Email">{(id) => <Input id={id} type="email" autoComplete="email" required value={email} onChange={(e) => setEmail(e.target.value)} />}</Field>
          <Field label="Password">
            {(id) => <Input id={id} type="password" autoComplete="current-password" required value={password} onChange={(e) => setPassword(e.target.value)} />}
          </Field>
          {error && <p role="alert" className="text-sm text-danger">{error}</p>}
          <Button type="submit" variant="primary" loading={busy} disabled={!email || !password} className="mt-2 w-full justify-center">
            Sign in
          </Button>
        </form>
      ) : (
        <form onSubmit={onLink} className="mt-6 flex flex-col gap-4" noValidate>
          <Field label="Email" hint={sent ? "We sent a sign-in link and a 6-digit code. Open the link on this device, or enter the code." : undefined}>
            {(id, d) => <Input id={id} aria-describedby={d} type="email" autoComplete="email" required value={email} disabled={sent} onChange={(e) => setEmail(e.target.value)} />}
          </Field>
          {sent && (
            <Field label="6-digit code">
              {(id) => (
                <Input id={id} inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]*" maxLength={6} value={code} onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))} className="tabular tracking-[0.3em]" />
              )}
            </Field>
          )}
          {error && <p role="alert" className="text-sm text-danger">{error}</p>}
          <Button type="submit" variant="primary" loading={busy} disabled={!email || (sent && code.length < 6)} className="mt-2 w-full justify-center">
            {sent ? "Verify code" : "Email me a link"}
          </Button>
          {sent && (
            <Button variant="link" onClick={() => { setSent(false); setCode(""); }} className="self-start text-sm">
              Use a different email
            </Button>
          )}
        </form>
      )}
    </AuthFrame>
  );
}

export function WelcomePage() {
  const { session, loading } = useAuth();
  const { profiles, loading: pLoading, setActive } = useProfileContext();
  const search = useSearch({ from: "/welcome" });
  const navigate = useNavigate();
  const create = useCreateProfile();
  const [name, setName] = useState("");
  const [key, setKey] = useState("");
  const [keyTouched, setKeyTouched] = useState(false);
  const effectiveKey = keyTouched ? key : profileKeyFromName(name);
  const keyValid = /^[a-z0-9_-]{2,40}$/.test(effectiveKey);

  if (loading || pLoading) return <Splash />;
  if (!session) return <Navigate to="/signin" />;
  if (profiles.length > 0 && !search.new) return <Navigate to="/" />;

  const onSubmit = (e: FormEvent) => {
    e.preventDefault();
    create.mutate(
      { name: name.trim(), key: effectiveKey },
      {
        onSuccess: (code) => {
          setActive(code);
          void navigate({ to: "/" });
        },
      },
    );
  };

  return (
    <AuthFrame>
      {profiles.length > 0 && (
        <Link to="/" className="mb-6 inline-flex items-center gap-1.5 text-sm text-muted hover:text-ink">
          <ArrowLeft className="size-4" /> Back to my ledger
        </Link>
      )}
      <p className="mb-2 text-[11px] font-medium tracking-[0.1em] text-subtle uppercase">{profiles.length ? "Another ledger" : "First run"}</p>
      <h1 className="font-display text-[34px] leading-[1.1] tracking-[-0.015em] text-ink">Create your ledger</h1>
      <p className="mt-2 text-sm text-muted">
        A ledger holds one person's cards, statements and SMS. You'll own it and can invite others later. Default categories and rules are added for you.
      </p>
      <form onSubmit={onSubmit} className="mt-8 flex flex-col gap-4">
        <Field label="Name" hint="Shown in the ledger switcher, e.g. “Personal” or “Household”.">
          {(id, d) => <Input id={id} aria-describedby={d} required maxLength={80} value={name} onChange={(e) => setName(e.target.value)} autoFocus />}
        </Field>
        <Field
          label="Key"
          hint="Used by the statement scraper's X-Profile-Key header. Lowercase letters, numbers, - and _."
          error={name && !keyValid ? "Use 2–40 lowercase letters, numbers, - or _." : undefined}
        >
          {(id, d) => (
            <Input
              id={id}
              aria-describedby={d}
              aria-invalid={!!name && !keyValid}
              value={effectiveKey}
              onChange={(e) => {
                setKeyTouched(true);
                setKey(e.target.value.toLowerCase());
              }}
              className="font-mono text-[13px]"
            />
          )}
        </Field>
        {create.error && (
          <p role="alert" className="text-sm text-danger">
            {/duplicate|already exists/i.test(errorMessage(create.error)) ? "That key is taken. Choose another." : errorMessage(create.error)}
          </p>
        )}
        <Button type="submit" variant="primary" loading={create.isPending} disabled={!name.trim() || !keyValid} className="mt-2 w-full justify-center">
          Create ledger
        </Button>
      </form>
    </AuthFrame>
  );
}
