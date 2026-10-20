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
        <a className="workers-link" href="/workers">Public demos</a>
        <a className="github-link" href="https://github.com/leostera/midgard">GitHub</a>
        <a className="nav-cta" href="/#deploy">Get started</a>
      </nav>
    </header>
  );
}

function Footer() {
  return (
    <footer className="footer">
      <span>Midgard <span className="muted">· Elixir platform for BEAM apps</span></span>
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
      <span className="worker-status"><i /> Published</span>
    </a>
  );
}

function WorkerInventory({ compact = false }: { compact?: boolean }) {
  const state = useLoad(getWorkers, "workers");
  if (state.status === "loading") return <p className="state-message">Loading public demos…</p>;
  if (state.status === "error") return <p className="state-message">The worker inventory is temporarily unavailable.</p>;
  if (state.value.length === 0) {
    return <p className="state-message">No public demos yet. Deploy one with <code>mix midgard.deploy</code> to list it here.</p>;
  }
  const workers = compact ? state.value.slice(0, 3) : state.value;
  return <div className="worker-list">{workers.map((worker) => <WorkerCard key={worker.slug} worker={worker} />)}</div>;
}

const workerLanguages = ["Elixir", "Gleam", "Erlang"];

function RotatingLanguage() {
  const [index, setIndex] = useState(0);
  useEffect(() => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const timer = window.setInterval(() => {
      setIndex((current) => (current + 1) % workerLanguages.length);
    }, 2_400);
    return () => window.clearInterval(timer);
  }, []);
  return <><span className="sr-only">Elixir, Gleam, and Erlang</span><span className="rotating-word" aria-hidden="true" key={workerLanguages[index]}>{workerLanguages[index]}</span></>;
}

function Landing() {
  return (
    <>
      <section className="hero">
        <div className="hero-copy">
          <h1>Serverless <RotatingLanguage /></h1>
          <p className="hero-platform">running on Cloudflare</p>
          <p className="hero-intro">Deploy Elixir, Erlang, and Gleam code as immutable BEAM shipments. Midgard’s Elixir platform runs them with libbeam in a Cloudflare Container.</p>
          <div className="hero-actions">
            <a className="button button-primary" href="#deploy">Deploy a worker</a>
            <a className="button button-quiet" href="/workers">Explore public demos</a>
          </div>
        </div>
        <div className="hero-value">
          <p>Elixir platform + native libbeam</p>
          <p>One public URL per deployment</p>
        </div>
      </section>

      <section className="deploy-section" id="deploy">
        <div className="section-heading"><h2>From Mix project to public URL</h2><p>Install the CLI, create a starter project, and publish a callable BEAM shipment. This shared demo is public—don’t upload secrets or private code.</p></div>
        <div className="terminal-card">
          <div className="quickstart-steps">
            <div><span>01</span><strong>Install the CLI</strong><pre><code>mix archive.install github leostera/midgard --app midgard_cli --sparse apps/midgard_cli --force</code></pre></div>
            <div><span>02</span><strong>Create a project</strong><pre><code>mix midgard.new hello_world{"\n"}cd hello_world && mix deps.get</code></pre></div>
            <div><span>03</span><strong>Deploy</strong><pre><code>mix midgard.deploy</code></pre></div>
          </div>
        </div>
      </section>

      <section className="inventory-preview">
        <div className="inventory-title"><h2>Try the public demos</h2><a href="/workers">Browse all demos</a></div>
        <WorkerInventory compact />
      </section>
    </>
  );
}

function InventoryPage() {
  return (
    <main className="page-main">
      <div className="page-heading"><h1>Public demo workers</h1><p>Every deployment here is visible and callable by anyone. The shared demo has no private projects or access controls; don’t upload secrets or private code.</p></div>
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
        <p className="detail-copy">This BEAM shipment runs through Midgard’s Elixir platform. Anyone with its public URL can call it; each deployment gets its own immutable URL.</p>
        <div className="detail-box"><span>PUBLIC URL</span><a href={state.value.url}>{new URL(state.value.url, window.location.origin).href}</a></div>
        <a className="button button-primary" href={state.value.url}>Open worker</a>
        <div className="detail-meta"><span>Shipment SHA-256</span><code>{state.value.digest.slice(0, 16)}…</code><span>Shipment size</span><code>{state.value.size.toLocaleString()} bytes</code></div>
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
  else if (pathname !== "/") page = <main className="page-main"><div className="empty-state"><h1>Page not found</h1><a href="/">Return to Midgard</a></div></main>;
  return <div className="site"><Header />{page}<Footer /></div>;
}
