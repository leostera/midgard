# Erlang HTTP-shaped worker

A standalone Rebar3 application (`erlang_worker`) uses the published `midgard_erlang` SDK from Hex. Its Erlang application and module remain named `midgard`. The worker's binary `handle/1` parses the `midgard.bytes.v1` request envelope, handles routes, and creates greeting bodies. `midgard:encode_response/1` encodes a `#midgard_response{}` framework value. The example serves `GET /hello` and `GET /hello/:name`; other routes return 404. The worker runs in libbeam, not an Erlang web server.

The published `rebar3_midgard` plugin adds `rebar3 midgard pack`, `inspect`, and `deploy`. Its shared Packer/deploy backend is distributed as Mix archives; install them once:

```sh
mix archive.install hex midgard_packer --force
mix archive.install hex midgard_cli --force
```

Requires Rebar3, Elixir, and Mix. Rebar3 fetches the SDK and plugin from Hex using the versions in `rebar.config`; no Midgard checkout is required.

```sh
# From the Midgard repository root:
(cd examples/erlang_worker && rebar3 eunit)
(cd examples/erlang_worker && rebar3 midgard pack)
(cd examples/erlang_worker && rebar3 midgard inspect)
(cd examples/erlang_worker && rebar3 midgard deploy)
```

`rebar.config` declares the pinned Hex SDK and plugin, plus the entry module, function, and protocol. The plugin runs Rebar3's compile provider first and packages the compiled dependency graph with the shared Packer. After deploying, append `/hello` or `/hello/joe` to the printed route prefix and open it in a browser. [Try the deployed Erlang example](https://erlang-worker-d10ea914d31ec739.midgard.leostera.dev/hello/joe): `GET /hello/joe` responds with `hello, joe!` as `text/plain`; `/hello` defaults to `hello, world!`. Each redeploy receives a new immutable route. The direct Hex versions for the SDK and plugin are pinned in `rebar.config`; commit `rebar.lock` as well to lock their resolved dependency graph. The platform verifies the exact shipment and admits its complete BEAM group before reporting it live. A zero-blocker static report alone does not prove execution.
