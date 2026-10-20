# rebar3_midgard

Build and ship an Erlang worker from the Rebar3 workflow you already use. The plugin adds `pack`, `inspect`, and `deploy` under `rebar3 midgard`, while keeping route handling and application behavior in your Erlang project.

## Project setup

Declare the Erlang SDK and project plugin in `rebar.config`:

```erlang
{deps, [{midgard, "0.2.0", {pkg, midgard_erlang}}]}.
{project_plugins, [{rebar3_midgard, "0.2.0"}]}.
{midgard, [
    {entry, my_worker},
    {function, handle},
    {protocol, "midgard.bytes.v1"}
]}.
```

These packages are published on Hex. Rebar3 fetches the plugin and SDK from the project configuration; no Midgard repository checkout is needed.

## Commands

```sh
rebar3 eunit
rebar3 midgard pack
rebar3 midgard inspect
rebar3 midgard deploy
```

- `pack` runs Rebar3's normal compile provider, then creates a `.midgard` artifact from the application and its compiled dependencies.
- `inspect` checks the artifact structure and reports static compatibility information. It does not execute the worker.
- `deploy` packages and uploads the artifact, then prints its worker URL.

## Requirements

The plugin delegates artifact assembly and upload to Midgard's shared Mix archives, so the host also needs Elixir/Mix and the Packer and CLI archives. Install those once:

```sh
mix archive.install hex midgard_packer --force
mix archive.install hex midgard_cli --force
```

In repository development and tests, local `_checkouts` symlinks may provide the plugin and SDK. Published projects use the Hex dependencies declared in `rebar.config`.

See the [Erlang example](../../examples/erlang_worker/README.md) and [project guide](../../docs/erlang-projects.md) for a complete worker.
