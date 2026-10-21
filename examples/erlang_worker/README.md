# Erlang worker

A standalone Rebar3 application that uses the `midgard_erlang` SDK and the `rebar3_midgard` plugin from Hex. `handle/1` passes each request to `midgard:serve/2`, which decodes the `midgard.bytes.v1` frame, calls `handle_request/1`, and encodes the `#midgard_response{}`. The worker runs in libbeam, not an Erlang web server.

| Request | Response |
| --- | --- |
| `GET /` | `Hello Joe!` |
| `GET /hello` | `hello, world!` |
| `GET /hello/joe` | `hello, joe!` |
| anything else | 404 |

[Try the deployed Erlang example](https://erlang-worker-5d88f8d4c07a3841.midgard.leostera.dev/).

> Midgard is a tech demo. It requires OTP 29.

## Run it

The plugin delegates packaging and upload to Midgard's shared Mix archives, so you need Rebar3, Elixir, and Mix. Install the archives once:

```sh
mix archive.install hex midgard_packer --force
mix archive.install hex midgard_cli --force
```

Then, from this directory:

```sh
rebar3 eunit
rebar3 midgard pack
rebar3 midgard inspect
rebar3 midgard deploy
```

`rebar.config` pins the SDK and plugin versions and declares the entry module, function, and protocol. `rebar.lock` locks the resolved dependency graph. The plugin runs Rebar3's compile provider, then packages the compiled application and its dependencies with the shared Packer.

Each deploy prints a new, immutable Worker URL. The platform verifies the exact shipment and admits its complete BEAM group before reporting it live; a clean static report alone does not prove execution.

In this repository, `_checkouts/` symlinks point the example at the local SDK and plugin sources so changes can be tested before release. Your own projects only need the Hex dependencies in `rebar.config`.
