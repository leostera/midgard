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

Packer runs the trusted Gleam compiler's `export erlang-shipment`, includes only `.app`-declared production modules, and refuses native resources. Gleam's undeclared generated CLI `@@main` is not a worker module. Gleam dependencies, including `gleam_stdlib` when declared, must be packaged, not silently omitted to pass a single route. A structurally valid artifact alone does not establish whole-application libbeam admission or execution.

To publish the built artifact, run `mix midgard.deploy --artifact examples/gleam_worker/amber_worker.midgard` from the repository root. This repository example's exact two-module shipment was verified, admitted, and called through libbeam:

```sh
curl -X POST -H 'Content-Type: application/octet-stream' \
  --data-binary 'hello' \
  'https://midgard.leostera.dev/run/amber_worker_16f327441c6fc766/'
# hello
```

Open the [live browser preview](https://midgard.leostera.dev/run/amber_worker_16f327441c6fc766/) to see `hello` as text. Midgard's HTTP adapter sends those sample bytes through the raw-byte Isolate; the worker itself does not implement HTTP or `GET /hello`. Add `?input=your-text` to preview another short UTF-8 input. Exact binary calls use `POST` at the route root with at most 32 KiB of request bytes and return `application/octet-stream`. Each new deployment receives a new immutable route. This fixture's successful execution does not guarantee that another Gleam project's full library closure runs in libbeam.
