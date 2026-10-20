# rebar3_midgard

A Rebar3 provider plugin for Midgard. It adds these namespaced tasks:

```sh
rebar3 midgard pack
rebar3 midgard inspect
rebar3 midgard deploy
```

Configure the worker's exported entrypoint in `rebar.config`:

```erlang
{deps, [{midgard, "0.1.0"}]}.
{project_plugins, [{rebar3_midgard, "0.1.0"}]}.
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

After the archives are published to Hex, the clone-free installs will be:

```sh
mix archive.install hex midgard_packer --force
mix archive.install hex midgard_cli --force
```

Those Hex releases are not published yet. The repository example resolves these pinned versions from local `_checkouts` symlinks. Once `midgard` and `rebar3_midgard` are published to Hex, standalone projects can use the same declarations and Rebar3 will fetch them automatically; users will not need to clone Midgard. These packages are not published yet.
