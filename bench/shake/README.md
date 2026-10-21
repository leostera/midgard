# Tree-shaking prototype (RFD0003)

Exploratory code behind [RFD0003](../../docs/rfds/RFD0003-tree-shaken-worker-shipments.md).
Not Packer code and not supported.

```sh
# Shake an artifact; writes DST.midgard and DST.midgard.report.json
elixir bench/shake/shake.exs SRC.midgard DST.midgard

# Diagnostics
SHAKE_WALK_ONLY=1 SHAKE_WHY="Elixir.Kernel:apply/3" elixir bench/shake/shake.exs SRC DST
SHAKE_MODE=sound ...            # widen unknown-name calls (keeps nearly everything)
SHAKE_ROOTS=elixir:start/2 ...  # extra roots the runtime calls itself
SHAKE_BEHAVIOURS=1 ...          # keep behaviour callbacks of referenced modules
```

Run it with the pinned Elixir toolchain the artifact was built with.

## Verifying a shaken shipment on OTP

`swap.erl` boots `:elixir` from its real modules, then hot-loads every BEAM in
`$SWAP_DIR` over them, so every later call runs shaken code and a wrongly
dropped function fails with `undef`. Put the shipment's non-OTP modules
(owners `elixir`, `logger`, `iex`, `midgard`, the app) in `$SWAP_DIR` and
serve the worker with `bench/container/midgard_http.erl`:

```sh
erlc -o /tmp/bench-ebin bench/container/midgard_http.erl bench/shake/swap.erl
SWAP_DIR=/tmp/shaken-non-otp MIDGARD_ENTRY_MODULE=Elixir.MyWorker \
MIDGARD_ENTRY_FUNCTION=__midgard_call__ PORT=18302 \
  erl -noshell -pa /tmp/bench-ebin -pz "$ELIXIR_EBIN" -s swap start
```

Compare its responses with the same worker started from the unshaken modules.
