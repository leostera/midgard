# Midgard

**Write Elixir serverless workers. Package BEAM workers from Elixir, Erlang, or Gleam for libbeam Isolates.**

Midgard is a worker toolchain: start from a Mix, rebar3, or Erlang-target Gleam project, build a versioned artifact containing your worker and its compiled dependencies, and inspect what you would hand to an Isolate host. Each BEAM keeps its original module name; the manifest records the entrypoint, protocol, dependency ownership, compiler provenance, and checksums. This makes a worker's complete code shipment visible instead of hiding it behind a local OTP installation.

**The framework effort is Elixir-first.** Today you can write an Elixir request handler with `Midgard.Worker`. You can also package Erlang and Gleam workers that export their own binary entrypoint, but Midgard does not provide request-handling APIs for those languages. They do not need to use Elixir or imitate its API. The common boundary is the artifact and its declared byte protocol, leaving room for language-specific APIs later.

## Install and deploy

Elixir workers must be built with **OTP 29** and Elixir source revision
`13299af2b91a6aff7e430f25849f586c02b3231f`, matching the live runtime. Packer
rejects other Elixir source revisions before creating an artifact. Install that
compiler first:

```sh
git clone https://github.com/elixir-lang/elixir.git /tmp/midgard-elixir
git -C /tmp/midgard-elixir checkout 13299af2b91a6aff7e430f25849f586c02b3231f
make -C /tmp/midgard-elixir compile install PREFIX=/tmp/midgard-toolchain
export PATH="/tmp/midgard-toolchain/bin:$PATH"
```

Then install or update the CLI and deploy a worker:

```sh
mix archive.install github leostera/midgard --app midgard_cli --sparse apps/midgard_cli --force
mix midgard.new hello_world
cd hello_world
mix deps.get
mix test
mix midgard.deploy
```

No token or account is needed. Deployment builds on your machine and prints a new, immutable **Route prefix**. Append a path your worker handles; the generated worker responds at `/hello` (and `/`). For example, replace the route ID below with the one printed by your deploy:

```sh
curl https://midgard.leostera.dev/run/hello_world_0123456789abcdef/hello
```

Already have a worker project? Reinstall the archive with `--force`, then run `mix midgard.deploy` inside that project. Its original route remains unchanged; a new deploy receives a new route. Archive installation executes code from GitHub; review and trust the source before installing it. The generated project pins its SDK and Packer dependencies to the same Git commit as the installed CLI.

## Write an Elixir worker

The Elixir SDK lets you write a request handler while it provides the binary worker entrypoint:

```elixir
defmodule MyWorker do
  use Midgard.Worker

  @impl true
  def handle_request(%Midgard.Request{method: "GET", path: "/hello"}),
    do: {200, "Hello!\n"}

  def handle_request(_request), do: {404, "Not found\n"}
end
```

Elixir workers must use Elixir source revision `13299af2b91a6aff7e430f25849f586c02b3231f` on OTP 29, matching the live runtime. Packer rejects other Elixir source revisions before building a shipment.

```sh
cd examples/hello_worker
mix deps.get
mix test
mix midgard.build
mix packer.inspect hello_worker.midgard
```

You'll get `hello_worker.midgard/`, with `manifest.json` and the worker's exact-name BEAM files under `modules/`. Tests exercise the request handler on ordinary OTP; inspection checks the artifact and reports static compatibility information. See the [Elixir worker API](docs/worker-request-api.md) for the request fields and response contract.

Install the CLI from Git with one Mix command:

```sh
mix archive.install github leostera/midgard --sparse apps/midgard_cli --app midgard_cli
mix midgard.new my_worker
cd my_worker && mix deps.get && mix test
mix midgard.deploy
# Copy the Route printed above and append hello, for example:
curl https://midgard.leostera.dev/run/my_worker_0123456789abcdef/hello
```

The archive supplies the Mix tasks; the new project fetches its SDK and Packer
from the **same pinned Git commit**. Before building an Elixir worker, compile
and select the exact runtime Elixir source revision above:

```sh
git clone https://github.com/elixir-lang/elixir.git /tmp/midgard-elixir
git -C /tmp/midgard-elixir checkout 13299af2b91a6aff7e430f25849f586c02b3231f
make -C /tmp/midgard-elixir compile install PREFIX=/tmp/midgard-toolchain
export PATH="/tmp/midgard-toolchain/bin:$PATH"
```

Archive installation runs source code from
the repository; review and trust it before installing. To develop against a
local checkout, pass `--midgard-root /path/to/midgard` to `mix midgard.new`
instead. The default deploy target is `https://midgard.leostera.dev`; no token
or account is required. Each deploy gets a **new, immutable public route**, printed
by the CLI and listed on the dashboard. The shared demo is limited to 32 live
shipments and 24 MB per upload; there is no authenticated ownership or overwrite.
Use `--endpoint http://127.0.0.1:4000` for a local platform with a matching
native libbeam host; see [local platform setup](apps/midgard_platform/README.md).
The generator never overwrites an existing path.

## Bring an Erlang or Gleam worker

| Language/project | What you write | What Midgard packages | Get started |
| --- | --- | --- | --- |
| Elixir or mixed Mix | An Elixir `Midgard.Worker` handler, optionally calling Erlang modules | Compiled app and runtime Mix dependencies | [HelloWorker](examples/hello_worker/README.md), [mixed worker](examples/mixed_worker/README.md) |
| Standalone Erlang/rebar3 | An exported binary-to-binary function with a declared byte protocol | One compiled app and its dependencies | [Erlang worker](examples/erlang_worker/README.md) |
| Erlang-target Gleam | An exported `BitArray -> BitArray` function with a declared byte protocol | Production Erlang shipment and declared dependencies | [Gleam worker](examples/gleam_worker/README.md) |

The [build and inspect guide](docs/packer.md) has the commands for each project type. The [Erlang guide](docs/erlang-projects.md) covers rebar3 and mixed Mix projects. The [to-do example](examples/todo/README.md) shows an Elixir/Erlang worker behind a local HTTP UI on ordinary OTP.

## From artifact to running worker

`mix midgard.deploy` now builds a complete original-BEAM dependency closure
locally and uploads it to the public Elixir platform through a rate-limited edge
Worker. The platform verifies its exact manifest and checksums, admits the group
to libbeam, then publishes `/run/:route/...` and shows it as Deployed in the
public inventory. The edge stores the exact shipment durably and re-verifies and
re-admits it after a Container restart before serving it again. No server-side
source compilation or per-call Container exec is involved. `mix packer.inspect
--target current-core` is a conservative static diagnostic, not evidence of
native admission. Anonymous demo routes are immutable, not private accounts;
this is not a production tenant-isolation or availability guarantee.

Build only trusted source: compilers, dependencies, and macros run with your developer privileges. An execution host will need to independently verify and admit the entire BEAM group and enforce its own resource and authority policy. For maintainers, [RFD0002](docs/rfds/RFD0002-artifact-and-worker-contract.md) specifies the implemented artifact and byte contracts.
