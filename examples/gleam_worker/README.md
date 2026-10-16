# Gleam HTTP-shaped worker

This Erlang-target Gleam package has a locked, local production dependency. Its binary `amber_worker.handle/1` parses the same `midgard.bytes.v1` request envelope used by the Elixir SDK and returns the same status/body response envelope. It serves `GET /hello` and `GET /hello/:name`; other routes return 404. The worker runs in libbeam, not an Erlang web server.

```sh
# From the Midgard repository root:
(cd examples/gleam_worker && gleam build --target erlang)
mix packer.pack --project examples/gleam_worker --gleam \
  --entry amber_worker --function handle --protocol midgard.bytes.v1
mix packer.inspect examples/gleam_worker/amber_worker.midgard
mix midgard.deploy --artifact examples/gleam_worker/amber_worker.midgard
```

After deploying, append `/hello` or `/hello/joe` to the printed route prefix and open it in a browser. `GET /hello/joe` responds with `Hello from joe\n` as `text/plain`; unlike the earlier raw-byte echo fixture it does **not** return an attachment.

Packer runs the trusted Gleam compiler's `export erlang-shipment`, includes only `.app`-declared production modules, and refuses native resources. Gleam's undeclared generated CLI `@@main` is not a worker module. All declared production dependencies must be packaged. The public host independently verifies and admits the exact BEAM group; successful execution of this small example does not guarantee that another Gleam project's library closure runs in libbeam.
