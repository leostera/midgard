# rebar3_midgard

A Rebar3 provider plugin for Midgard. It adds these namespaced tasks:

```sh
rebar3 midgard pack
rebar3 midgard inspect
rebar3 midgard deploy
```

Configure the worker's exported entrypoint in `rebar.config`:

```erlang
{plugins, [rebar3_midgard]}.
{midgard, [
    {entry, my_worker},
    {function, handle},
    {protocol, "midgard.bytes.v1"}
]}.
```

`pack` depends on Rebar3's normal `compile` provider, then calls the shared Packer Mix archive with `--skip-compile` so compilation is not repeated. `deploy` runs `pack` first and delegates upload to the Midgard CLI archive. This keeps artifact validation and deployment behavior shared with Elixir and Gleam projects.

## Tool requirements

The plugin itself is Erlang/Rebar3. The current shared Packer and deploy tasks are distributed as Mix archives, so the host also needs Elixir/Mix and both archives installed:

```sh
mix archive.install github leostera/midgard --app packer --sparse apps/packer --force
mix archive.install github leostera/midgard --app midgard_cli --sparse apps/midgard_cli --force
```

When developing inside this repository, `_checkouts/rebar3_midgard` points to this package. Published projects should add `rebar3_midgard` as a version-pinned Rebar3 plugin.
