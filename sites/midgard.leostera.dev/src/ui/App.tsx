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

const quickstartExamples: Record<QuickstartLanguage, QuickstartExample> = {
  elixir: {
    label: "Elixir",
    setupTitle: "Install and scaffold",
    setup: `mix archive.install github leostera/midgard --app midgard_cli --sparse apps/midgard_cli --force
mix midgard.new hello_worker
cd hello_worker
mix deps.get`,
    setupNote: "Use OTP 29 and the pinned Elixir before fetching dependencies.",
    sourceTitle: "Write the worker",
    source: `# lib/hello_worker.ex
defmodule HelloWorker do
  use Midgard.Worker

  @impl true
  def handle_request(%Midgard.Request{method: "GET", path: "/hello/" <> name}) when name != "",
    do: {200, HelloWorker.Greeting.hello(name)}

  def handle_request(_request), do: {404, "Not found\\n"}
end

# lib/hello_worker/greeting.ex
defmodule HelloWorker.Greeting do
  def hello(name), do: "hello, " <> name <> "!"
end

# midgard.config.exs (generated)
[entry: HelloWorker, target: :libbeam]`,
    sourceFile: "lib/hello_worker.ex + midgard.config.exs",
    sourceNote: "The scaffold also creates mix.exs, dependencies, tests, and the pinned project README.",
    sourceUrl: "https://github.com/leostera/midgard/blob/main/apps/midgard_cli/lib/midgard/cli/generator.ex",
    buildTitle: "Test and publish",
    build: `mix test
mix midgard.deploy`,
    buildNote: "The CLI prints your immutable worker URL and a call hint for /hello/:name.",
  },
  gleam: {
    label: "Gleam",
    setupTitle: "Get the toolchain",
    setup: `git clone https://github.com/leostera/midgard.git
cd midgard
mix archive.install github leostera/midgard --app midgard_cli --sparse apps/midgard_cli --force`,
    setupNote: "Requires Gleam and OTP 29. This uses the complete working example in examples/gleam_worker.",
    sourceTitle: "Handle a request",
    source: `fn dispatch(method: BitArray, path: BitArray) -> BitArray {
  case method, path {
    <<"GET":utf8>>, <<"/hello":utf8>> ->
      amber_helper.response(200, amber_helper.hello(<<"world":utf8>>))
    <<"GET":utf8>>, <<"/hello/":utf8, name:bits>> ->
      case name {
        <<>> -> not_found()
        _ ->
          case valid_name(name) {
            True -> amber_helper.response(200, amber_helper.hello(name))
            False -> not_found()
          }
      }
    _, _ -> not_found()
  }
}

fn valid_name(name: BitArray) -> Bool {
  case name {
    <<>> -> True
    <<"/":utf8, _rest:bits>> -> False
    <<_byte, rest:bits>> -> valid_name(rest)
    _ -> False
  }
}

fn not_found() -> BitArray {
  amber_helper.response(404, <<"Not found\\n":utf8>>)
}`,
    sourceFile: "examples/gleam_worker/src/amber_worker.gleam",
    sourceNote: "Route excerpt; the complete file also frames midgard.bytes.v1 requests.",
    sourceUrl: "https://github.com/leostera/midgard/blob/main/examples/gleam_worker/src/amber_worker.gleam",
    buildTitle: "Build and publish",
    build: `(cd examples/gleam_worker && gleam build --target erlang)
mix packer.pack --project examples/gleam_worker --gleam \\
  --entry amber_worker --function handle --protocol midgard.bytes.v1
mix midgard.deploy --artifact examples/gleam_worker/amber_worker.midgard`,
    buildNote: "The Packer task builds the BEAM shipment; each deploy prints a new immutable worker URL.",
  },
  erlang: {
    label: "Erlang",
    setupTitle: "Get the toolchain",
    setup: `git clone https://github.com/leostera/midgard.git
cd midgard
mix archive.install github leostera/midgard --app midgard_cli --sparse apps/midgard_cli --force`,
    setupNote: "Requires rebar3 and OTP 29. This uses the complete working example in examples/erlang_worker.",
    sourceTitle: "Route a request",
    source: `route(<<"GET">>, <<"/hello">>) ->
    reply(200, erlang_helper:hello(<<"world">>));
route(<<"GET">>, <<"/hello/", Name/binary>>) ->
    case valid_name(Name) of
        true -> reply(200, erlang_helper:hello(Name));
        false -> reply(404, <<"Not found\\n">>)
    end;
route(_, _) -> reply(404, <<"Not found\\n">>).

valid_name(<<>>) -> false;
valid_name(Name) -> no_slash(Name).`,
    sourceFile: "examples/erlang_worker/src/erlang_worker.erl",
    sourceNote: "Route excerpt; the complete file also frames midgard.bytes.v1 requests.",
    sourceUrl: "https://github.com/leostera/midgard/blob/main/examples/erlang_worker/src/erlang_worker.erl",
    buildTitle: "Build and publish",
    build: `(cd examples/erlang_worker && rebar3 eunit)
mix packer.pack --project examples/erlang_worker --entry erlang_worker \\
  --function handle --protocol midgard.bytes.v1
mix midgard.deploy --artifact examples/erlang_worker/erlang_worker.midgard`,
    buildNote: "Packer includes the compiled app and dependencies; each deploy prints a new immutable worker URL.",
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
        <p>Pick a language to see its source and build steps. The shared demo is public—don’t upload secrets or private code.</p>
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
              <span>01</span>
              <strong>{example.setupTitle}</strong>
              <HighlightedCode source={example.setup} language="bash" />
              <small>{example.setupNote} {activeLanguage === "elixir" && <a href="https://github.com/leostera/midgard#install-and-deploy" target="_blank" rel="noreferrer">Toolchain instructions</a>}</small>
            </div>
            <div>
              <span>02</span>
              <strong>{example.sourceTitle}</strong>
              <small className="code-filename">{example.sourceFile}</small>
              <HighlightedCode source={example.source} language={activeLanguage} />
              <small>{example.sourceNote} <a href={example.sourceUrl} target="_blank" rel="noreferrer">Open full example</a></small>
            </div>
            <div>
              <span>03</span>
              <strong>{example.buildTitle}</strong>
              <HighlightedCode source={example.build} language="bash" />
              <small>{example.buildNote} Public calls use the worker subdomain; <code>/run/</code> stays internal.</small>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
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

      <Quickstart />

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
