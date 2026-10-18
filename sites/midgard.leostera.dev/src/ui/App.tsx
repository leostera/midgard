import { useEffect, useState } from "react";

type PublicWorker = {
  slug: string;
  name: string;
  url: string;
  digest: string;
  size: number;
};

type LoadState<T> =
  | { status: "loading" }
  | { status: "ready"; value: T }
  | { status: "error" };

function parseWorker(value: unknown): PublicWorker | null {
  if (typeof value !== "object" || value === null) return null;
  const row = value as Record<string, unknown>;
  if (
    typeof row.slug !== "string" ||
    typeof row.name !== "string" ||
    typeof row.url !== "string" ||
    typeof row.digest !== "string" ||
    !/^[a-f0-9]{64}$/.test(row.digest) ||
    typeof row.size !== "number" ||
    !Number.isSafeInteger(row.size) ||
    row.size < 0
  ) return null;
  return { slug: row.slug, name: row.name, url: row.url, digest: row.digest, size: row.size };
}

async function getWorkers(): Promise<PublicWorker[]> {
  const response = await fetch("/api/workers", { headers: { accept: "application/json" } });
  if (!response.ok) throw new Error("Could not load public workers");
  const body: unknown = await response.json();
  if (typeof body !== "object" || body === null || !("workers" in body) || !Array.isArray(body.workers)) {
    throw new Error("Invalid worker inventory");
  }
  const workers = body.workers.map(parseWorker);
  if (workers.some((worker) => worker === null)) throw new Error("Invalid worker inventory");
  return workers as PublicWorker[];
}

async function getWorker(slug: string): Promise<PublicWorker> {
  const response = await fetch(`/api/workers/${encodeURIComponent(slug)}`, { headers: { accept: "application/json" } });
  if (!response.ok) throw new Error("Worker not found");
  const worker = parseWorker(await response.json());
  if (!worker) throw new Error("Invalid worker response");
  return worker;
}

function useLoad<T>(load: () => Promise<T>, key: string): LoadState<T> {
  const [state, setState] = useState<LoadState<T>>({ status: "loading" });
  useEffect(() => {
    let current = true;
    setState({ status: "loading" });
    void load().then(
      (value) => { if (current) setState({ status: "ready", value }); },
      () => { if (current) setState({ status: "error" }); },
    );
    return () => { current = false; };
  }, [key]);
  return state;
}

type LandingLanguage = "elixir" | "erlang" | "gleam";
const languageNames: Record<LandingLanguage, string> = { elixir: "Elixir", erlang: "Erlang", gleam: "Gleam" };

function Header({ landingLanguage }: { landingLanguage: LandingLanguage | null }) {
  return (
    <header className="topbar">
      <a className="brand" href="/" aria-label="Midgard home">
        <span className="brand-mark" aria-hidden="true">M</span>
        <span>midgard<span className="brand-dot">.</span></span>
      </a>
      <nav aria-label="Main navigation">
        <a className="workers-link" href="/workers">Workers</a>
        {landingLanguage && Object.entries(languageNames)
          .filter(([language]) => language !== landingLanguage)
          .map(([language, name]) => <a className="language-link" href={language === "elixir" ? "/" : `/${language}`} key={language}>For {name}</a>)}
        <a className="github-link" href="https://github.com/leostera/midgard">GitHub</a>
        <a className="nav-cta" href={landingLanguage ? "#deploy" : "/#deploy"}>Deploy a worker</a>
      </nav>
    </header>
  );
}

function Footer() {
  return (
    <footer className="footer">
      <span>Midgard <span className="muted">· BEAM, admitted at the edge</span></span>
      <a href="https://github.com/leostera/midgard">Open source on GitHub</a>
    </footer>
  );
}

function WorkerCard({ worker }: { worker: PublicWorker }) {
  return (
    <a className="worker-card" href={`/workers/${encodeURIComponent(worker.slug)}`}>
      <span className="worker-card-main">
        <strong>{worker.name}</strong>
        <span className="worker-route">{worker.url}</span>
      </span>
      <span className="worker-status"><i /> Live</span>
    </a>
  );
}

function WorkerInventory({ compact = false }: { compact?: boolean }) {
  const state = useLoad(getWorkers, "workers");
  if (state.status === "loading") return <p className="state-message">Loading public workers…</p>;
  if (state.status === "error") return <p className="state-message">The worker inventory is temporarily unavailable.</p>;
  if (state.value.length === 0) {
    return <p className="state-message">No public workers yet. Deploy one from your terminal to see it here.</p>;
  }
  const workers = compact ? state.value.slice(0, 3) : state.value;
  return <div className="worker-list">{workers.map((worker) => <WorkerCard key={worker.slug} worker={worker} />)}</div>;
}

const workerLanguages = ["Elixir", "Erlang", "Gleam", "Elixir", "BEAM"];

function RotatingLanguage() {
  const [index, setIndex] = useState(0);
  useEffect(() => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const timer = window.setInterval(() => {
      setIndex((current) => (current + 1) % workerLanguages.length);
    }, 2_400);
    return () => window.clearInterval(timer);
  }, []);
  return <><span className="sr-only">Elixir, Erlang, Gleam, and BEAM</span><span className="rotating-word" aria-hidden="true" key={workerLanguages[index]}>{workerLanguages[index]}</span></>;
}

function Landing({ language }: { language: LandingLanguage }) {
  const title = language === "elixir" ? <RotatingLanguage /> : languageNames[language];
  const intro = {
    elixir: "Build an Elixir worker locally. Midgard verifies the BEAM shipment, admits it to an isolated runtime, and gives it a public route.",
    erlang: "Keep your Erlang project and toolchain. Package its BEAM modules, then deploy them to an isolated Midgard runtime.",
    gleam: "Build your Gleam project for Erlang. Midgard packages its BEAM modules, verifies the shipment, and gives it an isolated public runtime.",
  }[language];
  return (
    <>
      <section className="hero">
        <div className="hero-copy">
          <h1>Isolated<br /><em>{title} workers.</em></h1>
          <p className="hero-intro">{intro}</p>
          <div className="hero-actions">
            <a className="button button-primary" href="#deploy">Deploy a worker</a>
            <a className="button button-quiet" href="/workers">Browse workers</a>
          </div>
        </div>
        <div className="runtime-diagram" role="img" aria-label="Cloudflare edge routes a request to an isolated BEAM runtime">
          <div className="runtime-stage"><span>REQUEST</span><strong>Cloudflare edge</strong></div>
          <div className="runtime-connection"><span>routes to</span></div>
          <div className="runtime-stage"><span>EXECUTES IN</span><strong>Isolated BEAM runtime</strong></div>
        </div>
      </section>

      <section className="principles" aria-label="How Midgard works">
        <article><h2>Build locally</h2><p>Use your Elixir, Erlang, or Gleam toolchain. Midgard ships the compiled modules, not your source tree.</p></article>
        <article><h2>Admit before serving</h2><p>The native host verifies the shipment before making it callable.</p></article>
        <article><h2>Route at the edge</h2><p>Each deployment gets an immutable public route through a rate-limited Cloudflare Worker.</p></article>
      </section>

      <section className="deploy-section" id="deploy">
        <div className="section-heading">
          <h2>{language === "elixir" ? "Install. Create. Deploy." : `Use your existing ${languageNames[language]} project.`}</h2>
          <p>{language === "elixir" ? "Three steps from a clean machine to a live worker. Your source stays local; Midgard receives the compiled BEAM shipment." : `Keep your ${languageNames[language]} toolchain. Build locally, then package and deploy the BEAM shipment.`}</p>
        </div>
        {language === "elixir" ? <div className="terminal-card">
          <div className="quickstart-steps">
            <div><span>01</span><strong>Install the CLI</strong><pre><code>mix archive.install github leostera/midgard --app midgard_cli --sparse apps/midgard_cli --force</code></pre></div>
            <div><span>02</span><strong>Create a project</strong><pre><code>mix midgard.new hello_world{"\n"}cd hello_world && mix deps.get</code></pre></div>
            <div><span>03</span><strong>Deploy</strong><pre><code>mix midgard.deploy</code></pre></div>
          </div>
        </div> : <div className="language-guide">
          <p>Midgard packages compiled {languageNames[language]} projects without changing their source toolchain.</p>
          <a href={language === "erlang" ? "https://github.com/leostera/midgard/tree/main/docs/erlang-projects.md" : "https://github.com/leostera/midgard/tree/main/examples/gleam_worker"}>Read the {languageNames[language]} project guide</a>
        </div>}
      </section>

      <section className="inventory-preview">
        <div className="inventory-title"><h2>Public workers</h2><a href="/workers">View all workers</a></div>
        <WorkerInventory compact />
      </section>
    </>
  );
}

function InventoryPage() {
  return (
    <main className="page-main">
      <div className="page-heading"><h1>Public workers</h1><p>Deployments on the shared demo are public and callable. Private projects and accounts are not available yet.</p></div>
      <WorkerInventory />
    </main>
  );
}

function WorkerPage({ slug }: { slug: string }) {
  const state = useLoad(() => getWorker(slug), slug);
  return (
    <main className="page-main">
      <a className="back-link" href="/workers">All workers</a>
      {state.status === "loading" && <p className="state-message">Loading worker…</p>}
      {state.status === "error" && <div className="empty-state"><h1>Worker not found</h1><p>This route may have been removed or the public demo may be restarting.</p><a href="/workers">Browse public workers</a></div>}
      {state.status === "ready" && <div className="worker-detail">
        <h1>{state.value.name}<span className="brand-dot">.</span></h1>
        <p className="detail-copy">This worker is live in Midgard’s native runtime and callable through its immutable public route.</p>
        <div className="detail-box"><span>PUBLIC ROUTE</span><a href={state.value.url}>{new URL(state.value.url, window.location.origin).href}</a></div>
        <a className="button button-primary" href={`${state.value.url}hello`}>Call /hello</a>
        <div className="detail-meta"><span>Shipment digest</span><code>{state.value.digest.slice(0, 16)}…</code><span>Shipment size</span><code>{state.value.size.toLocaleString()} bytes</code></div>
      </div>}
    </main>
  );
}

export function App() {
  const pathname = window.location.pathname;
  const worker = pathname.match(/^\/workers\/([a-z][a-z0-9_]*_[0-9a-f]{16})$/);
  const landingLanguage: LandingLanguage | null = pathname === "/" ? "elixir" : pathname === "/erlang" ? "erlang" : pathname === "/gleam" ? "gleam" : null;
  const appLanguage: LandingLanguage = landingLanguage ?? "elixir";
  let page = <Landing language={appLanguage} />;
  if (pathname === "/workers") page = <InventoryPage />;
  else if (worker) page = <WorkerPage slug={worker[1]} />;
  else if (!landingLanguage) page = <main className="page-main"><div className="empty-state"><h1>Page not found</h1><a href="/">Back to Midgard</a></div></main>;
  return <div className={`site theme-${appLanguage}`}><Header landingLanguage={landingLanguage} />{page}<Footer /></div>;
}
