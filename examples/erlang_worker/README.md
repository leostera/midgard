# Erlang-only Packer fixture

One rebar3 application (`erlang_worker`) with a pure-Erlang checkout dependency (`erlang_helper`). Requires rebar3; for a temporary local installation, run `MIX_HOME=/tmp/midgard-rebar mix local.rebar --force` and use the installed executable under `/tmp/midgard-rebar/elixir/<elixir-otp>/rebar3`.

```sh
rebar3 eunit
# From the Midgard repository root:
mix packer.pack --project examples/erlang_worker --entry erlang_worker \
  --function handle --protocol raw.bytes.v1 --rebar3 /path/to/rebar3
mix packer.inspect examples/erlang_worker/erlang_worker.midgard
```

`handle/1` accepts and returns a binary. It is **not** an HTTP worker or the `midgard.bytes.v1` SDK. `rebar3` checkouts have a compiled app version in the manifest but are not lockfile-pinned. The artifact has not been loaded or run in libbeam; a zero-blocker static report does not prove execution.
