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

**Not production-ready:** this is a binary deployment core, not yet an HTTP
router, authentication layer, persistent artifact store, remote upload API,
rate limiter, or container image. Only trusted, staged, immutable local
shipment directories should be read. The Isolate is the BEAM verification and
capability boundary, not the Elixir-side JSON parser. The existing local
HelloWorker `.midgard/` directory still has only **32 BEAMs** and is rejected
by strict whole-group admission. The packer must produce its self-contained
closure before deploying HelloWorker through this directory interface; the
separate 381-BEAM test bundle is not substituted for it.

To build the development native host, see `../libbeam_elixir/README.md`. Tests:

```sh
cd apps/midgard_platform && mix test
LIBBEAM_PORT_NATIVE=1 mix test
```
