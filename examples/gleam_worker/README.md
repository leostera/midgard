# Gleam Erlang-target worker

This fixture is a single Gleam package with a locked, local production dependency. `amber_worker:handle/1` accepts and returns binary bytes (`BitArray` in Gleam); it is not an HTTP server or the Elixir SDK protocol.

```sh
cd examples/gleam_worker
gleam build --target erlang
cd ../..
mix packer.pack --project examples/gleam_worker --gleam \
  --entry amber_worker --function handle --protocol raw.bytes.v1
mix packer.inspect examples/gleam_worker/amber_worker.midgard
```

Packer runs the trusted Gleam compiler's `export erlang-shipment`, includes only `.app`-declared production modules, and refuses native resources. Gleam's undeclared generated CLI `@@main` is not a worker module. Gleam dependencies, including `gleam_stdlib` when declared, must be packaged, not silently omitted to pass a single route. A structurally valid artifact does not establish whole-application libbeam admission or execution. The minimal fixture has been checked against a local libbeam runner; broader Gleam library support remains provisional.
