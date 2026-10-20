# Erlang HTTP-shaped worker

A standalone rebar3 application (`erlang_worker`) uses the Midgard Erlang framework library from `packages/erlang`, checked out locally as `_checkouts/midgard`. The worker's binary `handle/1` parses the `midgard.bytes.v1` request envelope, handles routes, and creates greeting bodies. `midgard:encode_response/1` encodes a `#midgard_response{}` framework value. It serves `GET /hello` and `GET /hello/:name`; other routes return 404. The worker runs in libbeam, not an Erlang web server.

Requires rebar3. For a temporary installation, run `MIX_HOME=/tmp/midgard-rebar mix local.rebar --force` and use the installed executable under `/tmp/midgard-rebar/elixir/<elixir-otp>/rebar3`.

```sh
# From the Midgard repository root:
(cd examples/erlang_worker && /path/to/rebar3 eunit)
mix packer.pack --project examples/erlang_worker --entry erlang_worker \
  --function handle --protocol midgard.bytes.v1 --rebar3 /path/to/rebar3
mix packer.inspect examples/erlang_worker/erlang_worker.midgard
mix midgard.deploy --artifact examples/erlang_worker/erlang_worker.midgard
```

After deploying, append `/hello` or `/hello/joe` to the printed route prefix and open it in a browser. [Try the deployed Erlang example](https://erlang-worker-d10ea914d31ec739.midgard.leostera.dev/hello/joe): `GET /hello/joe` responds with `hello, joe!` as `text/plain`; `/hello` defaults to `hello, world!`. Each redeploy receives a new immutable route. Rebar3 checkout dependencies have a compiled version in the manifest but are not lockfile-pinned. The platform verifies the exact shipment and admits its complete BEAM group before reporting it live. A zero-blocker static report alone does not prove execution.
