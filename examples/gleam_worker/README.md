# Gleam worker

An Erlang-target Gleam project that uses the `midgard_gleam` SDK from Hex. `gleam_worker.handle/1` passes each request to `midgard.serve`, which decodes the `midgard.bytes.v1` frame, calls `handle_request`, and encodes the `midgard.Response`. The worker runs in libbeam, not an Erlang web server.

| Request | Response |
| --- | --- |
| `GET /` | `Hello Joe!` |
| `GET /hello` | `hello, world!` |
| `GET /hello/joe` | `hello, joe!` |
| anything else | 404 |

[Try the deployed Gleam example](https://gleam-worker-ae647f68f90eaef3.midgard.leostera.dev/).

> Midgard is a tech demo. It requires OTP 29.

## Run it

Gleam has no plugin mechanism for external build commands yet, so packaging and upload use Midgard's Mix archives. You need Gleam, Elixir, and Mix. Install the archives once:

```sh
mix archive.install hex midgard_packer --force
mix archive.install hex midgard_cli --force
```

Then, from this directory:

```sh
gleam build --target erlang
mix packer.pack --project . --gleam \
  --entry gleam_worker --function handle --protocol midgard.bytes.v1
mix packer.inspect gleam_worker.midgard
mix midgard.deploy --artifact gleam_worker.midgard
```

The same steps work in a project you create with `gleam new`; see the [Midgard README](../../README.md#gleam).

Packer runs the Gleam compiler's `export erlang-shipment`, includes only `.app`-declared production modules, and refuses native code in the project or its downloaded packages. Each deploy prints a new, immutable Worker URL. The public host independently verifies and admits the exact BEAM group; this example running does not guarantee that another Gleam project's dependencies run in libbeam.
