# Midgard for Gleam

Write Erlang-target Gleam workers for [Midgard](https://midgard.leostera.dev) with plain request and response types. The SDK handles the `midgard.bytes.v1` wire format; your application owns routing and response content.

> Midgard is a tech demo. It requires OTP 29.

## Install

Add the package to `gleam.toml`:

```toml
[dependencies]
midgard_gleam = "0.4.0"
```

## Handle a request

```gleam
import midgard

pub fn handle(input: BitArray) -> BitArray {
  midgard.serve(input, handle_request)
}

pub fn handle_request(request: midgard.Request) -> midgard.Response {
  case request.method, request.path {
    <<"GET":utf8>>, <<"/":utf8>> -> midgard.Response(200, <<"Hello Joe!":utf8>>)
    _, _ -> midgard.Response(404, <<"Not found\n":utf8>>)
  }
}
```

`midgard.serve` decodes the `midgard.bytes.v1` request frame, calls your handler, and encodes the response. Malformed frames receive a 400 response. `midgard.decode_request` and `midgard.encode_response` are also available if you want to own the entrypoint yourself.

The Hex package is named `midgard_gleam`; its Gleam module is imported as `midgard`. It does not supply an HTTP server or router; routes and application behavior stay in your worker. See the [Gleam worker example](https://github.com/leostera/midgard/tree/main/examples/gleam_worker) for build and deploy steps.
