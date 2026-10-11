# Minimal mixed Mix fixture

`MixedWorker.__midgard_call__/1` (Elixir) calls `:mixed_helper.echo/1` (Erlang from `src/mixed_helper.erl`). This is a raw binary fixture, not an HTTP request handler.

```sh
mix deps.get
mix test
mix packer.pack --protocol raw.bytes.v1
mix packer.inspect mixed_worker.midgard
```

The artifact contains both exact-name BEAMs under `mixed_worker` ownership. Its static profile is provisional; tests execute on ordinary OTP, not inside libbeam.
