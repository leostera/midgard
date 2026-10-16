# Package your worker

Packer turns your compiled Elixir, Erlang, or Gleam worker into an inspectable `<app>.midgard/` artifact: the worker entrypoint, original BEAM names, compiled dependencies, and checksums together in one handoff. Use it to see exactly what a future libbeam Isolate host would need to admit. **Packaging is available across these languages; the Midgard request-handling API is Elixir-only for now.**

You need Elixir 1.19 and OTP 27+ for the tooling, plus rebar3 or Gleam for those project types. Run these commands from the Midgard checkout unless you have installed the CLI in another project.

## Build

### Mix (Elixir or mixed Elixir/Erlang)

In a Mix worker project with `packer: [entry: HelloWorker]` in `mix.exs`:

```sh
mix deps.get
mix packer.pack
```

Alternatively, set `[entry: HelloWorker, target: :libbeam]` in `midgard.config.exs` and run `mix midgard.build`. Mix's compiled `lib/**/*.ex`, `src/**/*.erl`, and runtime dependencies are included. You can override a generic binary entrypoint with `--function NAME --protocol ID`.

### Standalone rebar3

```sh
mix packer.pack --project /path/to/app --entry erlang_worker \
  --function handle --protocol raw.bytes.v1 --rebar3 /path/to/rebar3
```

`--rebar3` is optional if `rebar3` is on your PATH. One application per project is supported; rebar3 umbrellas are not. Compiled checkout dependencies are included, but their versions are not lockfile-pinned. See the [Erlang worker example](../examples/erlang_worker/README.md).

### Erlang-target Gleam

```sh
mix packer.pack --project /path/to/app --gleam --entry amber_worker \
  --function handle --protocol raw.bytes.v1
```

Use `--gleam-bin PATH` to choose a compiler. Check in `manifest.toml`; the production Erlang shipment's `.app` lists determine which dependency BEAMs are included. A generated CLI launcher is excluded, but declared dependencies are not. Gleam supplies its own binary entrypoint; this does not import the Elixir worker API. See the [Gleam example](../examples/gleam_worker/README.md).

All three commands write `<app>.midgard/` by default; pass `--output DIR` to choose a destination. The artifact has a `manifest.json` and `modules/` directory. Mix/rebar3 use artifact format v1; Gleam uses v2.

## Inspect

```sh
mix packer.inspect /path/to/app.midgard
mix packer.inspect /path/to/app.midgard --target current-core
```

Inspection checks the manifest, checksums, BEAM identities, dependency ownership, and exported entrypoint, then reports known unsupported operations and unresolved imports. Use `--target current-core` to fail early on static blockers against a pinned libbeam profile. A passing report is useful preflight evidence, **not** a promise of execution on any libbeam revision; the manifest continues to say `execution: not_verified`.

## Before running a worker

Build only sources and dependencies you trust: local compilation executes build scripts and macros with your developer privileges. Packer rejects known direct host-authority imports, NIF loading, `on_load`, and obvious native inputs, but cannot certify dynamic behavior or provide a security sandbox. An Isolate host must recheck and admit the full shipment before execution. Midgard does not deploy or run artifacts yet. [RFD0002](rfds/RFD0002-artifact-and-worker-contract.md) records the format and verifier invariants.
