# Midgard local platform (development)

From the **Midgard repository root**, a trusted local browser can create an
Elixir worker, edit its source, deploy it to a libbeam Isolate and call its URL.

## Run it

Requires Docker (OrbStack works), OTP 28, the pinned Elixir checkout and the
sibling libbeam checkout. Build the two local executables once:

```sh
LIBBEAM_SOURCE="$(realpath ../otp)" apps/libbeam_elixir/native/build.sh
ELIXIR_SOURCE=/absolute/path/to/elixir apps/midgard_platform/priv/compiler/build-image.sh
iex -S mix
```

Open **http://127.0.0.1:4000**, click **Create worker**, enter a lowercase
name, edit the starter source and click **Compile & deploy**. The page shows
the live URL, e.g. `http://127.0.0.1:4000/run/hello_world/hello`. The path
after the worker name is passed unchanged as the worker request path. GET,
POST and other methods use the bounded `midgard.bytes.v1` request protocol;
responses currently include status and body, not custom response headers.

Draft source and versioned checked artifacts live under `.midgard-platform/`
in the directory where the command was started, ignored by Git. Override with
`MIDGARD_WORKSPACE=/absolute/path` and the loopback port with
`MIDGARD_PORT=4001`. Drafts survive restarts; Isolate handles do not. On
restart, workers show as drafts and need explicit redeployment. New revisions
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
libbeam's atomic whole-group admission. **This is not a passing
`Packer.Verifier` static report**: its conservative whole-bundle host-import
screen rejects e.g. an `Elixir.Application` → `Elixir.IO` import in the pinned
runtime closure. The loader's admission and the observed invoked routes are
separate evidence; bundling a provider does not grant the guest denied host
authority. Each deployment gets its own Isolate
at libbeam's default **256 MiB / 10 million work units** policy. The demo
worker produced 341 unmodified BEAMs and answered GET `/hello` in an Isolate.
A Port/Engine crash invalidates every handle and clears the live URL mapping.

The existing `examples/hello_worker/hello_worker.midgard/` is still only a
32-BEAM incomplete artifact and will not be silently completed by the
platform. The browser flow creates a *new* complete artifact from the
pinned compiler container. No Hex-published native ABI, production artifact
store, multi-user authentication or general remote upload API is claimed.

## Tests

```sh
mix test
LIBBEAM_PORT_NATIVE=1 MIDGARD_COMPILER_IMAGE=1 mix test
```

These are run from the repository root. The native/compiler tests require the
native host and pinned compiler image built above. The pure local tests need
neither Docker nor libbeam. For optional desktop/mobile browser coverage with
Chrome installed:

```sh
cd apps/midgard_platform
npm ci
CHROME_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" npm run test:browser
```

The browser check captures desktop/mobile screenshots under the gitignored
`.impeccable/review/` directory and verifies that a failed edit leaves the
previous deployment callable.
