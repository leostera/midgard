# Midgard for Gleam

Use familiar Gleam request and response types in an Erlang-target worker, then encode a response as the `midgard.bytes.v1` binary frame. Midgard supplies the small framework boundary; your application owns routing and response content.

## Install

Add the package to `gleam.toml`:

```toml
[dependencies]
midgard_gleam = "0.2.0"
```

## Handle a request

```gleam
import midgard

pub fn handle_request(request: midgard.Request) -> midgard.Response {
  case request.method, request.path {
    <<"GET":utf8>>, <<"/hello":utf8>> ->
      midgard.Response(status: 200, body: <<"Hello!\n":utf8>>)
    _, _ ->
      midgard.Response(status: 404, body: <<"Not found\n":utf8>>)
  }
}
```

The Hex package is named `midgard_gleam`; its Gleam module is still imported as `midgard`. The package defines data types and response encoding. It does not supply an HTTP server, router, or application behavior. See the [Gleam worker example](../../examples/gleam_worker/README.md) for the worker's binary entrypoint and build steps.
