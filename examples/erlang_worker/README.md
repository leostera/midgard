# Erlang-only Packer fixture

One rebar3 application (`erlang_worker`) with a pure-Erlang checkout dependency (`erlang_helper`). Requires rebar3; for a temporary local installation, run `MIX_HOME=/tmp/midgard-rebar mix local.rebar --force` and use the installed executable under `/tmp/midgard-rebar/elixir/<elixir-otp>/rebar3`.

```sh
rebar3 eunit
# From the Midgard repository root:
mix packer.pack --project examples/erlang_worker --entry erlang_worker \
  --function handle --protocol raw.bytes.v1 --rebar3 /path/to/rebar3
mix packer.inspect examples/erlang_worker/erlang_worker.midgard
```

`handle/1` accepts and returns a binary. It is **not** an HTTP worker or the `midgard.bytes.v1` SDK. `rebar3` checkouts have a compiled app version in the manifest but are not lockfile-pinned. A zero-blocker static report alone does not prove execution.

To publish the built artifact, run `mix midgard.deploy --artifact examples/erlang_worker/erlang_worker.midgard` from the repository root. The public host verifies and admits the exact two-module shipment; raw workers accept only `POST` to the route root with at most 32 KiB of request bytes and return `application/octet-stream`. This repository example was deployed and called through libbeam:

```sh
curl -X POST -H 'Content-Type: application/octet-stream' \
  --data-binary 'hello' \
  'https://midgard.leostera.dev/run/erlang_worker_021a8a3f076ceb0b/'
# hello
```

A new deployment receives a new immutable route. This example does not serve `GET /hello`.
