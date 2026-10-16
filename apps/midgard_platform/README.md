# Midgard platform core (development)

A first, single-container deployment registry over `libbeam_elixir`. It starts
one native Engine Port and places each deployment in its **own** libbeam
Isolate. `Midgard.Platform.deploy/3` reads an immutable local `.midgard/`
shipment, checks its manifest/files/checksums and asks libbeam to admit every
BEAM atomically before publishing the deployment. `call/2` dispatches the
already-framed binary request to the shipment's declared arity-one entrypoint.
Independent calls use correlated Port requests rather than making the registry
GenServer wait for guest execution.

```elixir
{:ok, platform} = Midgard.Platform.start_link()
{:ok, digest} = Midgard.Platform.deploy("tenant-a", "/path/to/worker.midgard")
{:ok, response_bytes} = Midgard.Platform.call("tenant-a", request_bytes)
:ok = Midgard.Platform.stop("tenant-a")
Supervisor.stop(platform)
```

`start_link/1` accepts the development native host path via `executable:`.
`deploy/3` accepts libbeam's `memory_limit_bytes:` and
`invocation_work_limit:` overrides. The default is still **256 MiB** and
10 million work units; overrides are explicit. `defer_denied_nif: true` opts
into libbeam's inert NIF-on-load module compatibility mode without granting
native execution. A Port/Engine crash restarts the registry via `:rest_for_one`
and loses all deployments: callers must explicitly redeploy; no stale isolate
handle is silently reused.

## Isolated Elixir compilation

The local compiler image is built from **tracked** Elixir source at commit
`13299af2b91a6aff7e430f25849f586c02b3231f` atop the pinned OTP 28
Elixir image. Build it once:

```sh
ELIXIR_SOURCE=/absolute/path/to/elixir priv/compiler/build-image.sh
```

`Midgard.Platform.Compiler.compile/3` invokes Docker by immutable image ID with
no network, a read-only filesystem, no capabilities, non-root UID, CPU/memory/
PID limits, and only the staged source/SDK read-only plus an output mount.
Failure or an unavailable image returns an error; it never runs `Code.compile_*`
or `elixirc` in the platform VM. Its container resolves the exact provider
BEAM closure from **its own** pinned Elixir/OTP installation and emits a
checksummed `.midgard/` directory. Strict libbeam whole-group admission then
runs independently. A tested SDK worker produced 341 unmodified BEAMs and
executed at the default Isolate limits. The container remains a development
sandbox, not a general untrusted multi-tenant isolation guarantee.

**Not production-ready:** this is a binary deployment core, not yet an HTTP
router, authentication layer, persistent artifact store, remote upload API,
rate limiter, or container image. Only trusted, staged, immutable local
shipment directories should be read. The Isolate is the BEAM verification and
capability boundary, not the Elixir-side JSON parser. The existing local
HelloWorker `.midgard/` directory still has only **32 BEAMs** and is rejected
by strict whole-group admission. The isolated compiler now produces a
self-contained directory for *new* single-module SDK workers; it does not
rewrite or silently supplement that existing HelloWorker artifact.

To build the development native host, see `../libbeam_elixir/README.md`. Tests:

```sh
cd apps/midgard_platform && mix test
LIBBEAM_PORT_NATIVE=1 mix test
```
