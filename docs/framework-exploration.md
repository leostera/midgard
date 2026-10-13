# Midgard framework across Erlang, Elixir, and Gleam — exploration

Status: **discussion draft, not an accepted API or runtime support claim**. This is a framework exploration, not a replacement for the [artifact contract](libbeam-artifact-contract.md). The older [Realm RFD](rfds/RFD0001-elixir-edge-runtime-on-beam-realms.md) is historical and superseded.

## What the framework should mean

Three distinct layers are easy to conflate:

1. **Host/platform** (not implemented): accepts HTTP, selects a versioned artifact, checks grants and limits, admits an Isolate, transports bytes, enforces deadlines, and maps failures to client responses. It alone may own network, filesystem, storage, secrets, and deployment control.
2. **Language-neutral invocation contract**: one exported `binary -> binary` BEAM function named in the artifact, with a declared, versioned byte protocol. The current `midgard.bytes.v1` HTTP frame is bounded and has no response headers; `raw.bytes.v1` is a different, uninterpreted byte contract. No Erlang term, PID, resource handle, or grant crosses this interface. An artifact format version is **not** a wire protocol version.
3. **Optional guest framework libraries**: language-specific codecs, request/response types, validation, and handler adapters. Their BEAMs are explicit, versioned dependencies in the artifact, not invisible host services. An app can instead implement the wire directly.

This separation lets an Erlang handler avoid Elixir, a Gleam handler avoid Elixir and rebar3, and an Elixir handler retain its familiar facade. All three must agree on **bytes and observable behavior**, not on an identical in-memory record/struct representation.

## Workers API comparison: what should bindings enable?

Cloudflare Workers is more than `fetch(request, env, ctx)`. `env` contains deployment-configured bindings with *resource-specific methods*, such as D1's `env.DB.prepare(sql).bind(value).first()` or `.all()`/`.run()`, KV, R2, service bindings, and Queues. D1 offers managed database access with SQLite semantics; it is **not** permission for a Worker to load an arbitrary SQLite shared library or open a database file. `ctx` also owns invocation-lifetime features such as `waitUntil`. A Midgard request wrapper without bindings would not provide the same application model.

| Workers API area | Midgard now | Plausible first counterpart |
| --- | --- | --- |
| `Request` / `Response` | Provisional Elixir request, bounded status/body response; no response headers | Common HTTP wire with idiomatic per-language APIs, then a separately versioned response-header extension |
| D1 SQL binding | None | An authorized workerd/Workers bridge calls a deployment's D1 binding where available; a separate host-owned SQLite service would be a different self-hosted backend, not D1 |
| KV, R2, service bindings, outbound `fetch` | None | Separate resource-typed brokers only as justified; do not expose arbitrary sockets or generic host calls |
| Secrets and configuration | No guest binding API | Host-owned named grants; secret bytes need not be revealed to guests if an operation can be performed on their behalf |
| `ctx.waitUntil`, streaming, WebSockets, events | None | Later lifecycle/transport contracts; a synchronous 64 KiB call is not an adequate substitute |

A **binding** would be a deployment-scoped authority mapping, not a module dynamically imported from the host. In a Cloudflare deployment, a future `DB` binding might grant selected operations on an existing D1 resource. In a self-hosted deployment, a separately built SQLite service could offer similar operations but not be mislabeled D1. Application code would receive a language-native `db` value and call an idiomatic API: conceptual `Midgard.SQLite.query(db, sql, [id])`, `midgard_sqlite:query(Db, Sql, [Id])`, or `sqlite.query(db, sql, [id])`. These are sketches, not existing APIs. The deployment policy decides which physical database `DB` names; guest request bytes, SQL text, or a manifest claim must not choose a new database or elevate permissions. The adapter sends only a bounded operation and parameters to the host, which verifies the invocation identity and grant, uses prepared parameters, caps rows/bytes/work, and returns a bounded result or error. Failure or timeout cannot undo a committed write by implication; any transaction API would need explicit semantics.

**Blocking runtime gap:** libbeam's currently published host API offers host-to-Isolate `start`/`call` with copied binary input and output, but no demonstrated guest-to-host request/reply broker. Its admitted BEAMs cannot simply invoke a D1 binding or a host SQLite handle. A binding design first needs an authenticated, bounded, cancellable guest-initiated operation path (or an equally explicit runtime primitive), plus work/memory charging and tests. We should prototype that path with one narrow read/query operation before declaring a database API. Today the artifact verifier allows only `required_capabilities: []`; grants would require a versioned artifact/host contract and separate host policy approval, not a nonempty field silently slipped into v1/v2.

### Ideal deployment: libbeam behind or inside workerd

The aspiration is for BEAM guest code to benefit from **existing Cloudflare Workers bindings**, not to clone D1/KV/R2/Queues inside Midgard. A bridge Worker owns its configured `env` and dispatches authorized binding operations; the guest receives only bounded values and errors, never an `env.DB` JavaScript object, a SQLite file descriptor, or raw secret credentials.

```text
HTTP → bridge Worker (fetch, env, ctx) → libbeam Isolate → BEAM handler
                  ↑                          │
                  └─ binding broker ← guest operation (DB/KV/R2/etc.)
                       │
                  env.DB / env.KV / env.R2 ...
```

The same guest API can use different host backends, but **D1 semantics must not be silently replaced by local SQLite**: consistency, transactions, availability, and error models differ. Choose each binding explicitly in deployment configuration and enforce per-deployment grants and invocation correlation at the broker.

There are materially different implementation paths:

1. **Bridge Worker + external libbeam service:** a Worker with real Cloudflare bindings talks over an explicitly authenticated service/transport to a separate libbeam host. This can test an end-to-end binding on the managed Workers platform without pretending native BEAM code runs inside Cloudflare's V8 isolate. The return broker channel still needs a real guest suspension/reply mechanism.
2. **Native libbeam integrated into a custom workerd build:** tighter placement, but requires C++ integration, lifecycle/scheduling/resource coordination, and a binding bridge. This is a **custom workerd build**, not something deployable as ordinary JavaScript in managed Cloudflare Workers. A self-hosted workerd config is not automatically entitled to Cloudflare-managed D1; supported bindings must be checked per environment.
3. **Compile libbeam into a Workers-supported Wasm module:** attractive packaging, but its current native scheduler/threads, BEAM loader, memory and host-call model would require a real port and profile validation; not a shortcut to running an OTP VM inside a Worker.

Start by proving one `DB` query end-to-end through path 1, with actual D1 on Cloudflare where available, then evaluate whether path 2 offers enough benefit to justify maintaining a workerd fork. Binding support is per-resource work; it cannot be inferred from the existence of `env` or from a host-to-Isolate binary call.

## Proposed first slice: one small HTTP handler contract

Keep the existing `midgard.bytes.v1` framing as the interoperable baseline rather than inventing an incompatible protocol for each language. Input: method, path, raw query, ordered duplicate-preserving lowercase headers, and complete binary body. Output: status 100..599 and complete binary body. The [current codec limits](worker-request-api.md) are the starting point: 64 KiB frame, 32 KiB request body, 32 headers; no response headers or streaming. Both the host and the guest adapter validate lengths and shapes. Invalid frames receive a bounded 400; invalid handler output or ordinary handler failure gets a bounded 500 **only if execution remains healthy enough to produce one**. The host still owns timeouts, crashes, and transport failures and must not misreport them as a successful handler response.

The user-facing idea is a single `handle_request(Request) -> Response` with language-native representations, plus an adapter exporting `__midgard_call__/1`. The adapter is part of the guest dependency closure, not generated host code. These sketches describe desired ergonomics; **only the Elixir API shown below exists today**:

```elixir
# Existing provisional SDK API, exercised on ordinary OTP, not in libbeam.
defmodule MyWorker do
  use Midgard.Worker

  @impl true
  def handle_request(%Midgard.Request{method: "POST", path: "/echo", body: body}),
    do: {200, body}

  def handle_request(_), do: {404, "Not found\n"}
end
```

```erlang
%% Proposed Erlang API, not implemented. A request tuple/record can avoid maps
%% in the smallest admitted runtime profile. Accessors keep its layout private.
-module(my_worker).
-behaviour(midgard_handler).
-export([handle_request/1, '__midgard_call__'/1]).

handle_request(Request) ->
    case {midgard_request:method(Request), midgard_request:path(Request)} of
        {<<"POST">>, <<"/echo">>} -> {200, midgard_request:body(Request)};
        _ -> {404, <<"Not found\n">>}
    end.

'__midgard_call__'(Bytes) -> midgard_handler:invoke(?MODULE, Bytes).
```

```gleam
// Proposed Gleam API, not implemented. Request/Response come from a Gleam
// package; the compiled BEAM exports a separate byte bridge as the entrypoint.
import midgard/request.{type Request}
import midgard/response.{type Response}

pub fn handle_request(request: Request) -> Response {
  case request.method, request.path {
    "POST", "/echo" -> response.new(200, request.body)
    _, _ -> response.new(404, <<"Not found\n":utf8>>)
  }
}
```

For Gleam, a small **audited Erlang FFI bridge or compiler-generated adapter** could call the Gleam function and implement the byte framing. It must be included as an exact-name BEAM and cannot silently rely on an unbundled Elixir or Gleam standard library. We need a spike to decide the bridge's concrete syntax and dependencies; the example above deliberately does not pretend a Gleam `@external` or generated module already exists. The existing Gleam echo fixture only exports a raw `BitArray -> BitArray` entrypoint.

## Responsibilities and invariants

- **Host** filters inbound headers and HTTP authority, owns routing/deployment and maps host failures; the guest router may choose an application path but never selects an artifact or grants itself privileges.
- **Adapters** accept exactly one bounded binary, reject trailing/invalid frames, preserve duplicate header order, encode one bounded response, and avoid atom creation from untrusted bytes. HTTP decoding of JSON, cookies, or query values should be opt-in libraries, not automatic dependencies of a minimal handler.
- **Packer** records the adapter and its full runtime dependency closure with original module names; the manifest points to the exported bridge and protocol. Build/inspect is not permission to invoke. Dependencies with NIFs, unpackaged `priv/` resources, or disallowed host imports are not silently removed.
- **Capability APIs** remain absent from v1. A future fetch/storage API requires a separate broker protocol and explicit artifact grants, not a direct call to `httpc`, `file`, `ets`, `crypto`, or a NIF. No implicit application startup, global registration, supervisor, logger, or group leader is promised in an Isolate.
- **Versions and errors**: adapters reject unknown wire versions. Changing the frame (for example adding response headers) requires a new protocol ID and conformance fixtures, not merely a new package version. Changes to language-native types must not silently alter the byte contract.

## Profile reality and staged validation

1. **Define cross-language golden frames** for each valid and invalid boundary: non-UTF8 body bytes, duplicate headers, maximum sizes, malformed/trailing input, and handler failure. Run adapters on ordinary OTP and compare exact response bytes, without claiming libbeam compatibility.
2. **Implement the smallest Erlang adapter** (no implicit `stdlib`/OTP services), test Packer's exact dependency closure and artifact v1. Try whole-group admission and real libbeam invocation, recording the first rejection and actual returned bytes.
3. **Prototype a Gleam bridge** against the same frames and artifact v2. Gleam-generated imports and its full declared standard library remain part of admission: packaging a simple Gleam module and running it alone does not establish `gleam_stdlib` support.
4. **Reconcile the existing Elixir SDK** to the shared conformance suite without pretending HelloWorker currently runs in libbeam. Its maps/structs, Jason, and Elixir runtime imports are a distinct, larger admission problem.
5. Only then consider a router combinator, response headers (`midgard.bytes.v2`), middleware, JSON helpers, or host-broker capabilities. None is necessary to prove the common invocation boundary.

The [Hex source-level inventory](hex-compatibility-inventory.md) helps prioritize API dependencies but is not an admitted-BIF list. Measure generated BEAM imports/opcodes and the whole dependency graph against a **specific tested** libbeam revision before promising a language profile.

## Tradeoffs and questions to decide before an RFD

- **One common HTTP frame vs. raw bytes only:** common frames buy portability and contract tests; raw bytes alone minimize guest code but force every worker to implement HTTP parsing and versioning. Should the first public promise be HTTP, or should non-HTTP event handlers be equally first-class?
- **A shared API shape vs. idiomatic APIs:** records/tuples, Elixir structs, and Gleam custom types can expose equivalent semantics without pretending their runtime representations or dependencies are equivalent.
- **Adapter entrypoint ownership:** hand-written per app, compiler-generated at build time, or a versioned SDK module with a short app shim? A pure SDK avoids magic; generation might be needed for Gleam FFI but must be reproducible and inspectable.
- **Routing and failure policy:** should v1 require a catch-all handler, or return a framework-owned 404 for unmatched routes? How much exception normalization is viable in each admitted profile?
- **State and capabilities:** do we initially promise strictly per-invocation pure handlers, or warm-instance state? The local to-do example's `gen_server` works on ordinary OTP and does not establish Isolate process/OTP-service support.

No framework implementation or multi-language parity is claimed by this note. Once these choices are resolved, promote the selected contract into a numbered proposal RFD and make its acceptance tests executable.
