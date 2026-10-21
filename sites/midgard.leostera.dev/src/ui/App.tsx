import { useEffect, useRef, useState, type KeyboardEvent } from "react";
import hljs from "highlight.js/lib/core";
import bash from "highlight.js/lib/languages/bash";
import elixir from "highlight.js/lib/languages/elixir";
import erlang from "highlight.js/lib/languages/erlang";
import type { LanguageFn } from "highlight.js";

const gleamLanguage: LanguageFn = (highlighter) => ({
  name: "Gleam",
  keywords: {
    keyword: "pub fn let assert case if use import as type opaque external const",
    literal: "True False",
    built_in: "todo panic",
  },
  contains: [
    highlighter.COMMENT("//", "$"),
    highlighter.QUOTE_STRING_MODE,
    highlighter.C_NUMBER_MODE,
    { className: "type", begin: /\b[A-Z][A-Za-z0-9_]*\b/ },
    { className: "title.function", begin: /\b[a-z_][A-Za-z0-9_]*(?=\s*\()/ },
  ],
});

hljs.registerLanguage("bash", bash);
hljs.registerLanguage("elixir", elixir);
hljs.registerLanguage("erlang", erlang);
hljs.registerLanguage("gleam", gleamLanguage);

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
      <span>Midgard</span>
      <a href="https://github.com/leostera/midgard/blob/main/LICENSE">MIT-licensed · open source on GitHub</a>
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
    return <p className="state-message">No public demos yet. Deploy a worker to see it here.</p>;
  }
  const workers = compact ? state.value.slice(0, 3) : state.value;
  return <div className="worker-list">{workers.map((worker) => <WorkerCard key={worker.slug} worker={worker} />)}</div>;
}

type RaceLanguage = "Elixir" | "Gleam" | "Erlang";
// Seconds from the deploy command starting: when it exits, and when the new
// version first answers. Medians of real runs: scripts/measure-deploy.sh and
// bench/cloudflare-containers/measure.sh, October 2026. Midgard: Packer 0.4.0
// with a warm shake cache (a machine's first Elixir deploy took ~34 s / 40 s).
type Lane = { deployed: number; live: number };
const raceTimings: Record<RaceLanguage, { midgard: Lane; container: Lane }> = {
  Elixir: { midgard: { deployed: 9.8, live: 15.4 }, container: { deployed: 17.3, live: 186.3 } },
  Gleam: { midgard: { deployed: 5.8, live: 11.7 }, container: { deployed: 16.0, live: 119.3 } },
  Erlang: { midgard: { deployed: 3.6, live: 13.8 }, container: { deployed: 22.1, live: 181.9 } },
};
const raceLanguages = Object.keys(raceTimings) as RaceLanguage[];
const raceSeconds = 5; // a whole race plays in this long, whatever its real length
const raceHoldSeconds = 3;

function formatSeconds(seconds: number): string {
  if (seconds < 60) return `${seconds.toFixed(seconds < 10 ? 1 : 0)} s`;
  const whole = Math.round(seconds);
  return `${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, "0")} min`;
}

function RaceLane({ name, lane, clock, scale }: { name: string; lane: Lane; clock: number; scale: number }) {
  const shown = Math.min(clock, lane.live);
  const status = clock >= lane.live ? `Live in ${formatSeconds(lane.live)}` : clock >= lane.deployed ? "Rolling out" : "Deploying";
  return (
    <div className={`race-lane${clock >= lane.live ? " is-live" : ""}`}>
      <div className="race-lane-label"><strong>{name}</strong><span>{status}</span></div>
      <div className="race-track">
        <span className="race-deploy" style={{ width: `${(Math.min(shown, lane.deployed) / scale) * 100}%` }} />
        <span className="race-wait" style={{ width: `${(Math.max(0, shown - lane.deployed) / scale) * 100}%` }} />
      </div>
    </div>
  );
}

function DeployRace() {
  const [language, setLanguage] = useState<RaceLanguage>("Elixir");
  const timings = raceTimings[language];
  const scale = Math.max(timings.midgard.live, timings.container.live);
  const [clock, setClock] = useState(scale);
  useEffect(() => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) { setClock(scale); return; }
    let frame = 0;
    const started = performance.now();
    const tick = (now: number) => {
      const elapsed = ((now - started) / 1000) % (raceSeconds + raceHoldSeconds);
      setClock(Math.min(scale, (elapsed / raceSeconds) * scale));
      frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  }, [scale]);
  return (
    <figure className="race" aria-label={`Time from deploy command to first response, ${language} worker`}>
      <div className="race-head">
        <div className="race-tabs" role="tablist" aria-label="Worker language">
          {raceLanguages.map((name) => (
            <button key={name} type="button" role="tab" aria-selected={name === language} className="race-tab" onClick={() => setLanguage(name)}>{name}</button>
          ))}
        </div>
        <span className="race-clock" aria-hidden="true">{formatSeconds(clock)}</span>
      </div>
      <RaceLane name="Midgard" lane={timings.midgard} clock={clock} scale={scale} />
      <RaceLane name="Cloudflare Containers" lane={timings.container} clock={clock} scale={scale} />
      <div className="race-legend" aria-hidden="true"><span><i className="race-deploy" />Deploy command</span><span><i className="race-wait" />Until the new version answers</span></div>
      <figcaption>
        The same hello-world worker, from running the deploy command to the first response from the new version.
        Medians of three runs from a laptop, October 2026. <a href="https://github.com/leostera/midgard/tree/main/bench">How we measured</a>
      </figcaption>
    </figure>
  );
}

type QuickstartLanguage = "elixir" | "gleam" | "erlang";
type QuickstartExample = {
  label: string;
  setupTitle: string;
  setup: string;
  setupNote: string;
  sourceTitle: string;
  source: string;
  sourceFile: string;
  sourceNote: string;
  sourceUrl: string;
  buildTitle: string;
  build: string;
  buildNote: string;
};

const quickstartLanguages: QuickstartLanguage[] = ["elixir", "gleam", "erlang"];

const archives = `mix archive.install hex midgard_packer --force
mix archive.install hex midgard_cli --force`;

const quickstartExamples: Record<QuickstartLanguage, QuickstartExample> = {
  elixir: {
    label: "Elixir",
    setupTitle: "Install and scaffold",
    setup: `mix archive.install hex midgard_cli --force
mix midgard.new hello_worker
cd hello_worker && mix deps.get`,
    setupNote: "Requires OTP 29 and the latest Elixir (main). The scaffold fetches midgard and midgard_packer from Hex.",
    sourceTitle: "Handle a request",
    source: `defmodule HelloWorker do
  use Midgard.Worker

  @impl true
  def handle_request(%Midgard.Request{method: "GET", path: "/"}) do
    {200, "Hello Joe!"}
  end
end`,
    sourceFile: "lib/hello_worker.ex",
    sourceNote: "Trimmed from the generated worker, which also answers /hello and /hello/:name and comes with tests.",
    sourceUrl: "https://github.com/leostera/midgard/blob/main/apps/midgard_cli/lib/midgard/cli/generator.ex",
    buildTitle: "Test and deploy",
    build: `mix test
mix midgard.deploy
curl https://hello-worker-<id>.midgard.leostera.dev/`,
    buildNote: "The deploy prints your worker's URL. Every deploy gets a new one."
  },
  gleam: {
    label: "Gleam",
    setupTitle: "Install and create a project",
    setup: `${archives}

gleam new hello_worker && cd hello_worker
gleam remove gleam_stdlib
gleam add midgard_gleam@0.4.0`,
    setupNote: "Requires Gleam, Elixir, and OTP 29. Gleam can't run external build tools yet, so packaging and deploys use Midgard's Mix archives. Removing gleam_stdlib keeps the shipment to your code and the SDK.",
    sourceTitle: "Handle a request",
    source: `import midgard

pub fn handle(input: BitArray) -> BitArray {
  midgard.serve(input, handle_request)
}

pub fn handle_request(request: midgard.Request) -> midgard.Response {
  case request.method, request.path {
    <<"GET":utf8>>, <<"/":utf8>> -> midgard.Response(200, <<"Hello Joe!":utf8>>)
    _, _ -> midgard.Response(404, <<"Not found\\n":utf8>>)
  }
}`,
    sourceFile: "src/hello_worker.gleam",
    sourceNote: "The complete worker. midgard.serve decodes each request and encodes your response.",
    sourceUrl: "https://github.com/leostera/midgard/tree/main/examples/gleam_worker",
    buildTitle: "Build and deploy",
    build: `mix packer.pack --project . --gleam \\
  --entry hello_worker --function handle --protocol midgard.bytes.v1
mix midgard.deploy --artifact hello_worker.midgard`,
    buildNote: "The deploy prints your worker's URL. Every deploy gets a new one."
  },
  erlang: {
    label: "Erlang",
    setupTitle: "Install and create a project",
    setup: `${archives}

rebar3 new lib hello_worker && cd hello_worker
cat > rebar.config <<'EOF'
{erl_opts, [debug_info]}.
{deps, [{midgard, "0.4.0", {pkg, midgard_erlang}}]}.
{project_plugins, [{rebar3_midgard, "0.4.0"}]}.
{midgard, [{entry, hello_worker}, {function, handle},
           {protocol, "midgard.bytes.v1"}]}.
EOF`,
    setupNote: "Requires Rebar3, Elixir, and OTP 29. The rebar3_midgard plugin hands packaging and deploys to Midgard's Mix archives.",
    sourceTitle: "Handle a request",
    source: `-module(hello_worker).
-include_lib("midgard/include/midgard.hrl").
-export([handle/1]).

handle(Input) -> midgard:serve(Input, fun handle_request/1).

handle_request(#midgard_request{method = <<"GET">>, path = <<"/">>}) ->
    #midgard_response{status = 200, body = <<"Hello Joe!">>};
handle_request(_Request) ->
    #midgard_response{status = 404, body = <<"Not found\\n">>}.`,
    sourceFile: "src/hello_worker.erl",
    sourceNote: "The complete worker. midgard:serve/2 decodes each request and encodes your response.",
    sourceUrl: "https://github.com/leostera/midgard/tree/main/examples/erlang_worker",
    buildTitle: "Deploy",
    build: `rebar3 midgard deploy`,
    buildNote: "Compiles with Rebar3, packages the worker, and prints its URL. Every deploy gets a new one."
  },
};

function HighlightedCode({ source, language }: { source: string; language: QuickstartLanguage | "bash" }) {
  const html = hljs.highlight(source, { language, ignoreIllegals: true }).value;
  return <pre className="quickstart-code" tabIndex={0} aria-label={`${language} example code`}><code dangerouslySetInnerHTML={{ __html: html }} /></pre>;
}

function Quickstart() {
  const [activeLanguage, setActiveLanguage] = useState<QuickstartLanguage>("elixir");
  const tabRefs = useRef<Record<QuickstartLanguage, HTMLButtonElement | null>>({
    elixir: null,
    gleam: null,
    erlang: null,
  });
  const example = quickstartExamples[activeLanguage];

  function handleTabKeyDown(event: KeyboardEvent<HTMLButtonElement>, current: QuickstartLanguage) {
    const currentIndex = quickstartLanguages.indexOf(current);
    let nextIndex: number | undefined;
    if (event.key === "ArrowRight") nextIndex = (currentIndex + 1) % quickstartLanguages.length;
    if (event.key === "ArrowLeft") nextIndex = (currentIndex + quickstartLanguages.length - 1) % quickstartLanguages.length;
    if (event.key === "Home") nextIndex = 0;
    if (event.key === "End") nextIndex = quickstartLanguages.length - 1;
    if (nextIndex === undefined) return;
    event.preventDefault();
    const nextLanguage = quickstartLanguages[nextIndex];
    setActiveLanguage(nextLanguage);
    tabRefs.current[nextLanguage]?.focus();
  }

  return (
    <section className="deploy-section" id="deploy">
      <div className="section-heading">
        <h2>From worker code to public URL</h2>
        <p>Pick a language, write a handler, and deploy it to a public URL. Deployments are public, so don’t include secrets or private code.</p>
      </div>
      <div className="terminal-card">
        <div className="quickstart-tabs" role="tablist" aria-label="Worker language">
          {quickstartLanguages.map((language) => (
            <button
              key={language}
              ref={(element) => { tabRefs.current[language] = element; }}
              id={`quickstart-tab-${language}`}
              className="quickstart-tab"
              type="button"
              role="tab"
              aria-selected={activeLanguage === language}
              aria-controls="quickstart-panel"
              tabIndex={activeLanguage === language ? 0 : -1}
              onClick={() => setActiveLanguage(language)}
              onKeyDown={(event) => handleTabKeyDown(event, language)}
            >
              {quickstartExamples[language].label}
            </button>
          ))}
        </div>
        <div id="quickstart-panel" className="quickstart-panel" role="tabpanel" aria-labelledby={`quickstart-tab-${activeLanguage}`} tabIndex={0}>
          <div className="quickstart-steps">
            <div>
              <h3><span>01</span>{example.setupTitle}</h3>
              <HighlightedCode source={example.setup} language="bash" />
              <small>{example.setupNote}</small>
            </div>
            <div>
              <h3><span>02</span>{example.sourceTitle}</h3>
              <small className="code-filename">{example.sourceFile}</small>
              <HighlightedCode source={example.source} language={activeLanguage} />
              <small>{example.sourceNote} <a href={example.sourceUrl} target="_blank" rel="noreferrer">See the example project</a></small>
            </div>
            <div>
              <h3><span>03</span>{example.buildTitle}</h3>
              <HighlightedCode source={example.build} language="bash" />
              <small>{example.buildNote}</small>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

function Limitations() {
  return (
    <section className="limits-section" id="limits">
      <div className="section-heading">
        <h2>Before you try it</h2>
        <p>Midgard is a tech demo, not a hosting service. Here’s what that means in practice.</p>
      </div>
      <ul className="limits-list">
        <li><strong>Bleeding-edge toolchain.</strong> Requires OTP 29. Elixir workers also need Elixir <code>main</code> built at the runtime’s pinned revision.</li>
        <li><strong>Public and anonymous.</strong> There are no accounts. Anyone with a worker’s URL can call it, so don’t deploy secrets or private code.</li>
        <li><strong>Immutable deploys.</strong> Every deploy gets a new URL. You can’t update or delete an existing deployment.</li>
        <li><strong>Small, shared limits.</strong> Uploads are capped at 24 MB, and uploads and requests are rate-limited. Demos may be cleared at any time.</li>
        <li><strong>Not a full OTP node.</strong> Workers run on <a href="https://github.com/leostera/libbeam">libbeam</a>, so many libraries won’t run yet. Each shipment is checked before it’s admitted, but this is not a hardened sandbox.</li>
        <li><strong>Feedback welcome.</strong> Found a bug or have an idea? <a href="https://github.com/leostera/midgard/issues">Open an issue on GitHub</a>.</li>
      </ul>
    </section>
  );
}

function Landing() {
  return (
    <>
      <section className="hero">
        <div className="hero-copy">
          <h1>Serverless Elixir</h1>
          <p className="hero-intro">Deploy Elixir, Erlang, and Gleam workers. Every deployment gets its own immutable public URL.</p>
          <div className="hero-actions">
            <a className="button button-primary" href="#deploy">Deploy a worker</a>
            <a className="button button-quiet" href="/workers">Explore public demos</a>
          </div>
        </div>
        <DeployRace />
      </section>

      <Quickstart />

      <Limitations />

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
      <div className="page-heading"><h1>Public demo workers</h1><p>These workers are public: anyone with a URL can call them. Don’t deploy secrets or private code.</p></div>
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
        <p className="detail-copy">Anyone with this URL can call the worker. Every deployment gets its own immutable URL.</p>
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
