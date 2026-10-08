import { useEffect, useState, type FormEvent, type ReactNode } from "react";
import { Link, Navigate, useNavigate, useSearch } from "@tanstack/react-router";
import { ArrowLeft, Fingerprint, Mail } from "lucide-react";
import { CODE_MAX, CODE_MIN, cleanCode, sendEmailCode, signInErrorMessage, signInWithPasskey, useAuth, verifyEmailCode } from "@/data/auth";
import {
  conditionalMediationAvailable,
  listPasskeys,
  passkeyOfferDeclined,
  passkeysSupported,
  registerPasskey,
  setPasskeyOfferDeclined,
  shouldOfferPasskey,
} from "@/data/passkeys";
import { supabase } from "@/lib/supabase";
import { profileKeyFromName, useCreateProfile, useProfileContext } from "@/data/profile";
import { errorMessage } from "@/data/api";
import { Button } from "@/components/ui/button";
import { Field, Input } from "@/components/ui/input";
import { Splash, ThemeToggle } from "@/components/shell";
import { BrandLockup } from "@/components/brand/brand";

function AuthFrame({ children, footer }: { children: ReactNode; footer?: ReactNode }) {
  return (
    <div className="flex min-h-dvh flex-col bg-bg">
      <div className="flex items-center justify-between px-gutter py-4 md:px-gutter-lg">
        <BrandLockup />
        <ThemeToggle />
      </div>
      <main className="flex flex-1 items-start justify-center px-gutter pt-[8vh] pb-16">
        <div className="w-full max-w-[400px] animate-rise">{children}</div>
      </main>
      {footer}
    </div>
  );
}

type Step = "email" | "code" | "offer";

export function SignInPage() {
  const { session, loading } = useAuth();
  const [step, setStep] = useState<Step>("email");
  const [email, setEmail] = useState("");
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState<null | "send" | "verify" | "passkey" | "add">(null);
  const [error, setError] = useState<string | null>(null);
  // Verifying a code signs in before we know whether to offer a passkey: hold the redirect until then.
  const [holdRedirect, setHoldRedirect] = useState(false);
  const navigate = useNavigate();

  // Passkey autofill on the email field where the browser supports it. A later
  // explicit passkey or code sign-in cancels this pending request (auth-js does that).
  useEffect(() => {
    let live = true;
    void conditionalMediationAvailable().then((ok) => {
      if (ok && live) signInWithPasskey({ conditional: true }).catch(() => undefined);
    });
    return () => {
      live = false;
    };
  }, []);

  if (loading) return <Splash />;
  if (session && step !== "offer" && !holdRedirect) return <Navigate to="/" />;

  const run = async (kind: NonNullable<typeof busy>, fn: () => Promise<void>) => {
    setBusy(kind);
    setError(null);
    try {
      await fn();
    } catch (e) {
      setError(signInErrorMessage(e));
    } finally {
      setBusy(null);
    }
  };

  const onEmail = (e: FormEvent) => {
    e.preventDefault();
    void run("send", async () => {
      await sendEmailCode(email.trim());
      setCode("");
      setStep("code");
    });
  };

  const onCode = (e: FormEvent) => {
    e.preventDefault();
    setHoldRedirect(true);
    void run("verify", async () => {
      try {
        await verifyEmailCode(email.trim(), code);
      } catch (err) {
        setHoldRedirect(false);
        throw err;
      }
      const { data } = await supabase.auth.getUser();
      const userId = data.user?.id ?? "";
      const count = await listPasskeys().then((l) => l.length).catch(() => null);
      if (userId && shouldOfferPasskey({ supported: passkeysSupported(), declined: passkeyOfferDeclined(userId), passkeyCount: count })) setStep("offer");
      setHoldRedirect(false);
    });
  };

  const onPasskey = () =>
    void run("passkey", async () => {
      await signInWithPasskey();
    });

  const finishOffer = (declined: boolean) => {
    if (declined && session) setPasskeyOfferDeclined(session.user.id, true);
    void navigate({ to: "/" });
  };

  const onAddPasskey = () =>
    void run("add", async () => {
      const added = await registerPasskey();
      if (added) finishOffer(false);
    });

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
      {step === "offer" ? (
        <PasskeyOffer busy={busy === "add"} error={error} onAdd={onAddPasskey} onSkip={() => finishOffer(true)} />
      ) : (
        <>
          <p className="mb-2 text-[11px] font-medium tracking-[0.1em] text-subtle uppercase">Your card ledger</p>
          <h1 className="font-display text-[34px] leading-[1.1] tracking-[-0.015em] text-ink">Sign in</h1>
          <p className="mt-2 text-sm text-muted">Every purchase from your bank SMS, reconciled against your statements.</p>

          {step === "email" ? (
            <form onSubmit={onEmail} className="mt-8 flex flex-col gap-4" noValidate>
              <Field label="Email" hint="We'll email you a one-time code.">
                {(id, d) => (
                  <Input id={id} aria-describedby={d} type="email" autoComplete="email webauthn" required value={email} onChange={(e) => setEmail(e.target.value)} autoFocus />
                )}
              </Field>
              {error && <p role="alert" className="text-sm text-danger">{error}</p>}
              <Button type="submit" variant="primary" loading={busy === "send"} disabled={!email.trim() || !!busy} icon={<Mail className="size-4" />} className="mt-2 w-full justify-center">
                Email me a code
              </Button>
              {passkeysSupported() && (
                <>
                  <div className="flex items-center gap-3 text-[11px] tracking-[0.1em] text-subtle uppercase" aria-hidden>
                    <span className="h-px flex-1 bg-border" />
                    or
                    <span className="h-px flex-1 bg-border" />
                  </div>
                  <Button type="button" loading={busy === "passkey"} disabled={!!busy} icon={<Fingerprint className="size-4" />} onClick={onPasskey} className="w-full justify-center">
                    Sign in with a passkey
                  </Button>
                </>
              )}
            </form>
          ) : (
            <form onSubmit={onCode} className="mt-8 flex flex-col gap-4" noValidate>
              <p className="text-sm text-muted">
                We sent a sign-in code to <span className="font-medium text-ink">{email.trim()}</span>. It expires in an hour.
              </p>
              <Field label="Code">
                {(id) => (
                  <Input
                    id={id}
                    inputMode="numeric"
                    autoComplete="one-time-code"
                    pattern="[0-9]*"
                    maxLength={CODE_MAX}
                    value={code}
                    onChange={(e) => setCode(cleanCode(e.target.value))}
                    className="tabular tracking-[0.3em]"
                    autoFocus
                  />
                )}
              </Field>
              {error && <p role="alert" className="text-sm text-danger">{error}</p>}
              <Button type="submit" variant="primary" loading={busy === "verify"} disabled={code.length < CODE_MIN || !!busy} className="mt-2 w-full justify-center">
                Sign in
              </Button>
              <div className="flex flex-wrap justify-between gap-2">
                <Button
                  variant="link"
                  onClick={() => {
                    setStep("email");
                    setCode("");
                    setError(null);
                  }}
                  className="text-sm"
                >
                  Use a different email
                </Button>
                <Button variant="link" disabled={!!busy} onClick={() => void run("send", () => sendEmailCode(email.trim()))} className="text-sm">
                  Send a new code
                </Button>
              </div>
            </form>
          )}
        </>
      )}
    </AuthFrame>
  );
}

function PasskeyOffer({ busy, error, onAdd, onSkip }: { busy: boolean; error: string | null; onAdd: () => void; onSkip: () => void }) {
  return (
    <div>
      <span className="mb-5 inline-flex size-12 items-center justify-center rounded-full bg-accent-soft text-accent" aria-hidden>
        <Fingerprint className="size-6" />
      </span>
      <p className="mb-2 text-[11px] font-medium tracking-[0.1em] text-subtle uppercase">You're in</p>
      <h1 className="font-display text-[30px] leading-[1.1] tracking-[-0.015em] text-ink">Add a passkey?</h1>
      <p className="mt-2 text-sm text-muted">
        Next time, sign in with Face ID, Touch ID or your device's screen lock instead of waiting for an email code. Your passkey stays on your device and in your password manager.
      </p>
      {error && <p role="alert" className="mt-4 text-sm text-danger">{error}</p>}
      <div className="mt-8 flex flex-col gap-3">
        <Button variant="primary" loading={busy} icon={<Fingerprint className="size-4" />} onClick={onAdd} className="w-full justify-center">
          Add a passkey
        </Button>
        <Button variant="ghost" disabled={busy} onClick={onSkip} className="w-full justify-center">
          Not now
        </Button>
      </div>
      <p className="mt-4 text-[12px] text-subtle">You can add or remove passkeys any time in Settings → Account.</p>
    </div>
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
