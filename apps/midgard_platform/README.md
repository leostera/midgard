# Midgard local platform (development)

From the **Midgard repository root**, developers build locally, upload exact
`.midgard/` BEAM shipments to the loopback Elixir platform, and call admitted
workers through a libbeam Isolate. The Create page explains this workflow.

## Run it

Requires OTP 28, Elixir 1.19+, and a native libbeam host built for this
checkout. Docker is **not** needed for the CLI upload flow. In one terminal:

```sh
mix deps.get
LIBBEAM_SOURCE="$(realpath ../otp)" apps/libbeam_elixir/native/build.sh
mix run --no-halt
```

In another terminal, from the repository root:

```sh
mix midgard.new hello_worker --midgard-root .
cd hello_worker
mix deps.get
mix test
mix midgard.deploy --endpoint http://127.0.0.1:4000
curl http://127.0.0.1:4000/run/hello_worker/hello
```

The CLI compiles with the **developer's** Elixir/OTP, includes the full BEAM
import and external-fun closure, and uploads unchanged bytes. The local API
accepts a bounded binary shipment (`POST /api/deployments/:slug`); the serving
VM parses and verifies the manifest and checksums and admits the group without
compiling source. An invalid update leaves the old live Isolate callable.
`MIDGARD_DEPLOY_TOKEN` can be set on both CLI and server to require a shared
token during local tests. The public Container API instead accepts uploads
only from its DO gateway with a server-generated immutable route and a private
internal key. The public CLI never needs a deployment token. Ordinary direct
uploads to the Container are rejected.

Open **http://127.0.0.1:4000** and click **Create worker** for these steps.
After deploying, the Workers inventory lists the worker as Deployed and its
detail page shows the route prefix and module count. The sidebar links this
checkout's Git commit to GitHub. Search, status filters, sortable columns,
pagination, invocation totals, and GET/POST worker calls continue to work.
Existing local-only source-editor development endpoints remain available for
older drafts; CodeMirror still has its textarea fallback. Those endpoints are
not exposed publicly.

Draft source, per-worker invocation totals, and versioned checked artifacts live under `.midgard-platform/`
in the directory where the command was started, ignored by Git. Override with
`MIDGARD_WORKSPACE=/absolute/path` and the loopback port with
`MIDGARD_PORT=4001`. Drafts survive restarts; Isolate handles do not. On
restart, workers show as drafts and need explicit redeployment; invocation totals
persist across restarts and redeployments. A count increments for each valid,
protocol-bounded HTTP request routed to a live worker, including failed worker
calls, but excludes unknown workers and invalid or oversized requests. It is
local routing telemetry, not native Isolate CPU usage or external traffic.
New revisions
are admitted before the live URL switches; compilation/admission failures keep
the last working deployment online.

## Boundary and limitations

**Browser source is never compiled in the serving BEAM VM.** Docker runs it
as a non-root user in an immutable image built from tracked Elixir source commit
`13299af2b91a6aff7e430f25849f586c02b3231f` atop a pinned OTP 28 base.
The invocation has no network, a read-only filesystem, no capabilities, CPU/
memory/PID limits, a bounded wall-clock deadline and 64 KiB output cap, and only source/SDK read-only
and fresh output mounts. An unavailable image or Docker error fails closed.
Compile-time Elixir macros can execute *inside that container*. This is a
trusted-local tool, **not** an adversarial multi-tenant compiler security
boundary; do not bind the HTTP service publicly.

The compiler resolves the exact imported BEAM closure from its *own* pinned
Elixir/OTP installation, packages original names with SHA-256 records and
compiler-image provenance, and the host checks the shipment separately before
libbeam's atomic whole-group admission. Packer verifies module inventory and hashes; host-only imports in packaged
OTP/Elixir libraries are tolerated as **static diagnostics**, while
application and ordinary dependency modules still fail the host-import screen.
The loader's admission and the observed invoked routes are separate evidence;
bundling a library does not grant the guest denied host authority. The static
opcode/BIF profile can report thousands of unsupported or unresolved imports
in the whole closure even when the invoked route works: it is not libbeam
admission evidence. Each deployment gets its own Isolate
at libbeam's default **256 MiB / 10 million work units** policy. The demo
worker produced 341 unmodified BEAMs and answered GET `/hello` in an Isolate.
A Port/Engine crash invalidates every handle and clears the live URL mapping.

The editor currently supports a named Elixir module, nested modules, the
`Midgard.Worker` SDK, and modules available in its pinned Elixir/OTP image.
**Hex dependencies such as Jason are not installed** in this compiler image;
those imports fail closed rather than borrowing host libraries. The existing
`examples/hello_worker/hello_worker.midgard/` is still only a 32-BEAM
incomplete artifact and will not be silently completed by the platform. The
browser flow creates a *new* complete artifact from the pinned compiler
container. The CLI instead builds its closure on the developer's machine; this
can include Mix dependencies, but each worker must still pass libbeam
admission. No Hex-published native ABI or multi-user authentication is claimed. The
public demo's edge DO durably stores exact uploaded shipments and re-admits
them after Container restart, but does not provide private worker ownership.

## Tests

```sh
mix test
LIBBEAM_PORT_NATIVE=1 MIDGARD_COMPILER_IMAGE=1 mix test
MIDGARD_NATIVE_UPLOAD=1 mix test apps/midgard_platform/test/upload_flow_test.exs
```

These are run from the repository root. The native/compiler tests require the
native host and pinned compiler image built above. The pure local tests need
neither Docker nor libbeam. For optional desktop/mobile browser coverage with
Chrome installed:

```sh
cd apps/midgard_platform
npm ci
npm run build:editor
CHROME_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" npm run test:browser
```

The browser check captures desktop/mobile screenshots under the gitignored
`.impeccable/review/` directory and verifies that a failed edit leaves the
previous deployment callable.
