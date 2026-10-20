# Erlang HTTP-shaped worker

A standalone rebar3 application (`erlang_worker`) uses the Midgard Erlang framework library from `packages/erlang`, checked out locally as `_checkouts/midgard`. Its binary `handle/1` parses the `midgard.bytes.v1` request envelope, handles routes, and creates greeting bodies. `midgard:encode_response/1` encodes a `#midgard_response{}` framework value. The example serves `GET /hello` and `GET /hello/:name`; other routes return 404. The worker runs in libbeam, not an Erlang web server.

The `rebar3_midgard` plugin adds `rebar3 midgard pack` and `rebar3 midgard deploy`. Its current shared Packer/deploy backend is distributed as Mix archives, so install those once from the Midgard checkout:

```sh
mix archive.install hex midgard_packer --force
mix archive.install hex midgard_cli --force
```

Requires rebar3. For a temporary installation, run `MIX_HOME=/tmp/midgard-rebar mix local.rebar --force` and use the installed executable under `/tmp/midgard-rebar/elixir/<elixir-otp>/rebar3`.

```sh
# From the Midgard repository root:
(cd examples/erlang_worker && rebar3 eunit)
(cd examples/erlang_worker && rebar3 midgard pack)
(cd examples/erlang_worker && rebar3 midgard inspect)
(cd examples/erlang_worker && rebar3 midgard deploy)
```

`rebar.config` declares the entry module, function, and protocol. The plugin runs Rebar3's compile provider first and packages the compiled dependency graph with the shared Packer. After deploying, append `/hello` or `/hello/joe` to the printed route prefix and open it in a browser. [Try the deployed Erlang example](https://erlang-worker-d10ea914d31ec739.midgard.leostera.dev/hello/joe): `GET /hello/joe` responds with `hello, joe!` as `text/plain`; `/hello` defaults to `hello, world!`. Each redeploy receives a new immutable route. Rebar3 checkout dependency versions are recorded but not lockfile-pinned. The platform verifies the exact shipment and admits its complete BEAM group before reporting it live. A zero-blocker static report alone does not prove execution.
