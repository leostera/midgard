# Midgard Packer

Turn a compiled Mix, Rebar3, or Erlang-target Gleam worker into a `.midgard` package. Packer collects the worker's exact-name BEAM modules and compiled dependencies, then records the entrypoint, protocol, ownership, compiler metadata, and checksums in a manifest.

> Midgard is a tech demo. Elixir workers require OTP 29 and the latest Elixir (`main`) at the runtime's pinned revision; see the [toolchain instructions](https://github.com/leostera/midgard#elixir).

## Build and inspect

For a Mix worker, set the entrypoint in `mix.exs`:

```elixir
packer: [entry: MyWorker]
```

Then run:

```sh
mix packer.pack
mix packer.inspect my_worker.midgard
```

For a Rebar3 project, use the Rebar3 plugin (`rebar3 midgard pack` / `inspect`) or call Packer directly:

```sh
mix packer.pack --project path/to/worker --entry my_worker \
  --function handle --protocol midgard.bytes.v1
```

For Gleam, first build the Erlang target, then use `mix packer.pack --project path/to/worker --gleam --entry my_worker --function handle --protocol midgard.bytes.v1`.

Install the v0.3.0 archive from Hex:

```sh
mix archive.install hex midgard_packer --force
```

## What inspection means

Packer validates package structure without loading worker modules. Its compatibility report is a static diagnostic, not proof that a particular worker will execute successfully on a host. Packer does not run workers or provide the deployment command; use the Midgard CLI or a language-specific plugin for that.

Packer requires Elixir 1.19+ and OTP 27+ with OTP's `:json` module. See the [artifact guide](https://github.com/leostera/midgard/blob/main/docs/packer.md) and examples for full project configuration.
