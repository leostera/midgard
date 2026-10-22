// Sign-in and dashboard pages, built with Kumo. This module is loaded lazily,
// so Kumo's standalone stylesheet (which includes a CSS reset) only applies to
// these full-page routes and never to the landing page.
import "@cloudflare/kumo/styles/standalone";
import "./account.css";
import { useEffect, useState, type FormEvent } from "react";
import { Badge, Banner, Button, ClipboardText, Empty, Input, LayerCard, Loader, Text } from "@cloudflare/kumo";
import { EnvelopeSimple, Rocket, SignOut, WarningCircle } from "@phosphor-icons/react";

type Me = { email: string };

function Shell({ children, email }: { children: React.ReactNode; email?: string }) {
  async function signOut() {
    await fetch("/api/logout", { method: "POST" });
    window.location.assign("/");
  }
  return (
    <div className="account-shell">
      <header className="account-bar">
        <a className="account-brand" href="/" aria-label="Midgard home">
          <span className="account-mark" aria-hidden="true">M</span>
          <Text variant="heading3" as="span">midgard.</Text>
        </a>
        {email && (
          <div className="account-user">
            <Text variant="secondary" as="span">{email}</Text>
            <Button variant="ghost" size="sm" icon={SignOut} onClick={signOut}>Sign out</Button>
          </div>
        )}
      </header>
      <main className="account-main">{children}</main>
    </div>
  );
}

const errors: Record<string, string> = {
  invalid_email: "Enter a valid email address.",
  invalid_code: "That code is incorrect or has expired.",
  try_later: "Too many attempts. Wait a minute and try again.",
  email_unavailable: "We couldn't send the email right now. Try again shortly.",
};

export function LoginPage() {
  const [email, setEmail] = useState("");
  const [code, setCode] = useState("");
  const [sent, setSent] = useState(false);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusy(true);
    setError("");
    try {
      const response = await fetch(sent ? "/api/login/verify" : "/api/login/start", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(sent ? { email, code, client: "web" } : { email }),
      });
      const result = await response.json().catch(() => ({})) as { error?: string };
      if (!response.ok) throw new Error(errors[result.error ?? ""] ?? "Sign-in failed. Try again.");
      if (sent) window.location.assign("/dashboard");
      else setSent(true);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Sign-in failed. Try again.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <Shell>
      <LayerCard className="account-card">
        <LayerCard.Secondary>{sent ? "Step 2 of 2" : "Sign in"}</LayerCard.Secondary>
        <LayerCard.Primary>
          <form className="account-form" onSubmit={submit}>
            <div className="account-stack-sm">
              <Text variant="heading2" as="h1">{sent ? "Check your email" : "Sign in to Midgard"}</Text>
              <Text variant="secondary">
                {sent ? `We sent a six-digit code to ${email}. It expires in 10 minutes.` : "We'll email you a one-time code. No password needed."}
              </Text>
            </div>
            {error && <Banner variant="error" icon={<WarningCircle weight="fill" />} title={error} />}
            {sent ? (
              <Input
                label="Sign-in code"
                inputMode="numeric"
                autoComplete="one-time-code"
                pattern="[0-9]{6}"
                maxLength={6}
                required
                autoFocus
                value={code}
                onChange={(event) => setCode(event.target.value)}
              />
            ) : (
              <Input
                label="Email"
                type="email"
                autoComplete="email"
                placeholder="you@example.com"
                required
                autoFocus
                value={email}
                onChange={(event) => setEmail(event.target.value)}
              />
            )}
            <div className="account-actions">
              <Button type="submit" variant="primary" loading={busy} icon={sent ? undefined : EnvelopeSimple}>
                {sent ? "Verify and sign in" : "Email me a code"}
              </Button>
              {sent && (
                <Button type="button" variant="ghost" onClick={() => { setSent(false); setCode(""); setError(""); }}>
                  Use a different email
                </Button>
              )}
            </div>
          </form>
        </LayerCard.Primary>
      </LayerCard>
    </Shell>
  );
}

export function DashboardPage() {
  const [state, setState] = useState<{ status: "loading" } | { status: "signed-out" } | { status: "ready"; me: Me }>({ status: "loading" });

  useEffect(() => {
    void fetch("/api/me").then(async (response) => {
      if (!response.ok) return setState({ status: "signed-out" });
      setState({ status: "ready", me: await response.json() as Me });
    }, () => setState({ status: "signed-out" }));
  }, []);

  if (state.status === "loading") {
    return <Shell><div className="account-center"><Loader /></div></Shell>;
  }
  if (state.status === "signed-out") {
    return (
      <Shell>
        <div className="account-card">
          <Empty title="Sign in to see your workers" description="Your dashboard lists the workers you deploy while signed in." contents={<Button variant="primary" onClick={() => window.location.assign("/login")}>Sign in</Button>} />
        </div>
      </Shell>
    );
  }

  return (
    <Shell email={state.me.email}>
      <div className="account-heading">
        <div className="account-stack-sm">
          <Text variant="heading1" as="h1">Your workers</Text>
          <Text variant="secondary">Workers you deploy while signed in appear here.</Text>
        </div>
        <Badge variant="beta">Preview</Badge>
      </div>
      <Empty
        icon={<Rocket size={48} />}
        title="No workers yet"
        description="Sign in from your project, then deploy. The worker keeps its URL across updates."
        contents={
          <div className="account-commands">
            <ClipboardText text="mix midgard.login" />
            <ClipboardText text="mix midgard.deploy" />
          </div>
        }
      />
    </Shell>
  );
}
