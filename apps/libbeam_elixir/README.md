# libbeam_elixir (development package)

A supervised Elixir Port binding to real libbeam Isolates. One `Libbeam.Engine`
GenServer owns one native `libbeam_host` process; that process owns all native
handles on its host-control thread. Every Isolate has a separate libbeam world.
Calls complete asynchronously through correlated Port replies, so guest work
never runs on an Elixir scheduler. A Port exit invalidates all its handles.

**Not ready for Hex releases:** the host is temporarily linked to libbeam's
experimental C++ implementation. The libbeam team must provide a versioned
native distribution/C ABI and a compatible-version query before publishing.
The `libbeam-port-v2` handshake versions only this development wire protocol.

## Local build

```sh
LIBBEAM_SOURCE=/absolute/path/to/libbeam apps/libbeam_elixir/native/build.sh
mix compile
mix midgard.test
cd apps/libbeam_elixir && LIBBEAM_PORT_NATIVE=1 mix test
```

`build.sh` rebuilds libbeam with Bazel and links the native host from source.
The produced `priv/libbeam_host` is local and ignored by Git. No prebuilt
platform binaries or implicit lookup in a sibling checkout are shipped.

## API

```elixir
{:ok, engine} = Libbeam.Engine.start_link()
{:ok, isolate} =
  Libbeam.Engine.create_isolate(engine,
    virtual_time: [epoch_ms: 946_684_800_000, auto_advance: true]
  )
:ok = Libbeam.Isolate.load_modules(isolate, beam_binaries)
:ok = Libbeam.Isolate.advance_time(isolate, 250)
{:ok, result} = Libbeam.Isolate.call(isolate, "module", "function", request_bytes)
:ok = Libbeam.Isolate.stop(isolate) # waits for physical reclamation
:ok = Libbeam.Engine.shutdown(engine)
```

`beam_binaries` must be the complete, original-name, compatible BEAM closure.
The binding does **not** complete a `.midgard/` artifact on behalf of the packer.
Modules with an `on_load` denied-NIF marker may be included only by explicitly
passing `defer_denied_nif: true` to `load_modules/3`; such modules remain
unavailable, and the option grants no native-library authority. The default
Isolate resource limits remain libbeam's 256 MiB / 10,000,000 work units.
`create_isolate/2` accepts explicit `:memory_limit_bytes` and
`:invocation_work_limit` overrides; zero means use the default. Virtual time is
opt-in through `:virtual_time`, with `:epoch_ms` and optional idle
`:auto_advance`; `Libbeam.Isolate.advance_time/2` remains available for manual
clock control. Each Isolate owns its clock.

For the optional full-closure integration test, pass a complete `LBAPP001`
fixture as `LIBBEAM_PORT_NATIVE=1 LIBBEAM_HELLO_BUNDLE=/absolute/path/to/hello_worker.bundle mix test`.
This fixture test does not turn the existing 32-BEAM `.midgard/` artifact into
a self-contained package. Both GET and POST replies are compared byte-for-byte.

## `mix midgard.test` prototype

After building the native host, `mix midgard.test` discovers
`test/libbeam/**/*_test.exs` and `test/libbeam/**/*_test.erl`. Every case gets a
fresh Engine and Isolate with a fixed epoch and idle auto-advance by default.
Elixir files use the small `Midgard.Test` DSL (`use Midgard.Test`, `test`, and
`assert`); Erlang files export `run/1` and return `<<"ok">>` on success. Example:

```elixir
defmodule ArithmeticTest do
  use Midgard.Test

  test "addition" do
    assert 2 + 2 == 4
  end
end
```

Options include `--path`, `--epoch-ms`, and `--no-auto-advance`. This is an
integration prototype, **not an ExUnit replacement**: test modules must be
self-contained in the discovered files, and libbeam's supported BEAM
instructions, imports, and OTP services define the compatibility boundary.
It does not automatically load an application's dependency closure or provide
a security boundary for arbitrary test code. Unsupported BEAM may fail the
case or terminate the native host; run only trusted test modules in this
prototype.

## Development wire contract

Both directions use `{:packet, 4}` framing with a **32 MiB** maximum frame.
Commands: `<<1, request_id::64, opcode::8, payload::binary>>`. Responses:
`<<1, request_id::64, status::8, payload::binary>>`. Handshake uses request
ID zero and returns `libbeam-port-v2`. Operations 1–6 are create, atomic
module-group load, call, stop/reclaim, shutdown, and manual virtual-time
advance. Status zero returns success;
status one carries a bounded error code/message. The Engine GenServer never
waits for guest execution inside a callback: it stores `GenServer.from()`
and replies on the matching Port message. The native host polls pending calls
and reclamation handles on **the same thread** that created its Engine.

Currently `call/4` waits for a terminal reply and has no public cancellation or
per-call deadline. Native work limits are finite but are not wall-clock limits.
Do not expose this development package to untrusted traffic before adding
bounded caller deadlines, cancellation/backpressure, a native ABI version pin,
Port-exit tests under load and independently verified artifact admission.
