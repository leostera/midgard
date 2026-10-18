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

function Header() {
  return (
    <header className="topbar">
      <a className="brand" href="/" aria-label="Midgard home">
        <span className="brand-mark" aria-hidden="true">M</span>
        <span>midgard<span className="brand-dot">.</span></span>
      </a>
      <nav aria-label="Main navigation">
        <a href="/workers">Workers</a>
        <a href="https://github.com/leostera/midgard">GitHub <span aria-hidden="true">↗</span></a>
        <a className="nav-cta" href="#deploy">Deploy a worker <span aria-hidden="true">↗</span></a>
      </nav>
    </header>
  );
}

function Footer() {
  return (
    <footer className="footer">
      <span>Midgard <span className="muted">· BEAM, admitted at the edge</span></span>
      <a href="https://github.com/leostera/midgard">Open source on GitHub ↗</a>
    </footer>
  );
}

function WorkerCard({ worker }: { worker: PublicWorker }) {
  return (
    <a className="worker-card" href={`/workers/${encodeURIComponent(worker.slug)}`}>
      <span className="worker-icon" aria-hidden="true">λ</span>
      <span className="worker-card-main">
        <strong>{worker.name}</strong>
        <span className="worker-route">{worker.url}</span>
      </span>
      <span className="worker-status"><i /> Live</span>
      <span className="worker-arrow" aria-hidden="true">↗</span>
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

function Landing() {
  return (
    <>
      <section className="hero">
        <div className="hero-copy">
          <p className="eyebrow"><span className="pulse" /> ISOLATED WORKERS ON CLOUDFLARE</p>
          <h1>Isolated<br /><em><RotatingLanguage /> workers.</em></h1>
          <p className="hero-intro">Deploy Elixir, Erlang, and Gleam apps as isolated BEAM workers. Midgard admits compiled modules into native runtimes and routes requests to them at the edge—without compiling your source in the serving runtime.</p>
          <div className="hero-actions">
            <a className="button button-primary" href="#deploy">Deploy your first worker <span aria-hidden="true">↓</span></a>
            <a className="button button-quiet" href="/workers">Explore live workers <span aria-hidden="true">↗</span></a>
          </div>
          <p className="hero-note">Open demo · anonymous deploys · public routes</p>
        </div>
        <div className="hero-art" aria-label="A worker request flowing through Cloudflare to a native BEAM Isolate">
          <div className="orbit orbit-one" /><div className="orbit orbit-two" />
          <div className="node node-edge"><span>CF</span><small>edge</small></div>
          <div className="node node-beam"><span>λ</span><small>BEAM</small></div>
          <div className="flow-line"><i /><i /><i /></div>
          <div className="art-caption"><span className="art-live" /> native runtime <span>·</span> isolated execution</div>
        </div>
      </section>

      <section className="principles" aria-label="How Midgard works">
        <article><span className="step">01 / BUILD</span><h2>Your toolchain, your BEAMs</h2><p>Compile locally with your Elixir, Erlang, or Gleam toolchain. Midgard ships the exact compiled modules, not your source tree.</p></article>
        <article><span className="step">02 / ADMIT</span><h2>Prove it in the runtime</h2><p>The native host verifies the shipment and admits the complete module group before it becomes callable.</p></article>
        <article><span className="step">03 / ROUTE</span><h2>Reach it at the edge</h2><p>Each deployment receives an immutable public route. Calls enter through a rate-limited Cloudflare Worker.</p></article>
      </section>

      <section className="deploy-section" id="deploy">
        <div className="section-heading"><p className="eyebrow">GET STARTED</p><h2>From project to live route.</h2><p>Build and deploy from your terminal. Your code stays in your project; the shipment contains compiled BEAM files.</p></div>
        <div className="terminal-card">
          <div className="terminal-bar"><span /><span /><span /><small>terminal</small></div>
          <pre><code><span className="term-dim"># In your worker project</span>{"\n"}<span className="term-prompt">$</span> mix deps.get{"\n"}<span className="term-prompt">$</span> mix midgard.deploy{"\n\n"}<span className="term-success">✓</span> Deployed hello_worker · 378 BEAMs{"\n"}<span className="term-dim">  https://midgard.leostera.dev/run/hello_worker_…/</span></code></pre>
          <p className="terminal-footnote">The shown output is illustrative. Your route is returned after successful admission.</p>
        </div>
      </section>

      <section className="inventory-preview">
        <div className="inventory-title"><div><p className="eyebrow">THE PUBLIC DEMO</p><h2>Workers in the wild</h2></div><a href="/workers">View all workers <span aria-hidden="true">↗</span></a></div>
        <WorkerInventory compact />
      </section>
    </>
  );
}

function InventoryPage() {
  return (
    <main className="page-main">
      <div className="page-heading"><p className="eyebrow">PUBLIC DEMO</p><h1>Live workers<span className="brand-dot">.</span></h1><p>These deployments are public and callable. The demo currently has no accounts or private worker ownership.</p></div>
      <WorkerInventory />
    </main>
  );
}

function WorkerPage({ slug }: { slug: string }) {
  const state = useLoad(() => getWorker(slug), slug);
  return (
    <main className="page-main">
      <a className="back-link" href="/workers">← All workers</a>
      {state.status === "loading" && <p className="state-message">Loading worker…</p>}
      {state.status === "error" && <div className="empty-state"><h1>Worker not found</h1><p>This route may have been removed or the public demo may be restarting.</p><a href="/workers">Browse live workers →</a></div>}
      {state.status === "ready" && <div className="worker-detail">
        <p className="eyebrow"><span className="pulse" /> ADMITTED WORKER</p>
        <h1>{state.value.name}<span className="brand-dot">.</span></h1>
        <p className="detail-copy">This worker is live in Midgard’s native runtime and callable through its immutable public route.</p>
        <div className="detail-box"><span>PUBLIC ROUTE</span><a href={state.value.url}>{new URL(state.value.url, window.location.origin).href}</a></div>
        <a className="button button-primary" href={`${state.value.url}hello`}>Call /hello <span aria-hidden="true">↗</span></a>
        <div className="detail-meta"><span>Shipment digest</span><code>{state.value.digest.slice(0, 16)}…</code><span>Shipment size</span><code>{state.value.size.toLocaleString()} bytes</code></div>
      </div>}
    </main>
  );
}

export function App() {
  const pathname = window.location.pathname;
  const worker = pathname.match(/^\/workers\/([a-z][a-z0-9_]*_[0-9a-f]{16})$/);
  let page = <Landing />;
  if (pathname === "/workers") page = <InventoryPage />;
  else if (worker) page = <WorkerPage slug={worker[1]} />;
  else if (pathname !== "/") page = <main className="page-main"><div className="empty-state"><h1>Page not found</h1><a href="/">Back to Midgard →</a></div></main>;
  return <><Header />{page}<Footer /></>;
}
