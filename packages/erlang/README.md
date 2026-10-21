# Midgard Erlang SDK

Build Erlang workers for [Midgard](https://midgard.leostera.dev) with framework request/response records. The SDK handles the `midgard.bytes.v1` wire format; your application owns its routes and response behavior.

> Midgard is a tech demo. It requires OTP 29.

## Install

Add the SDK to `rebar.config`:

```erlang
{deps, [{midgard, "0.4.0", {pkg, midgard_erlang}}]}.
```

The Hex package is named `midgard_erlang`; the Erlang application and module remain `midgard`.

## Use

Export a binary entrypoint that hands each request to your handler:

```erlang
-module(hello_worker).
-include_lib("midgard/include/midgard.hrl").
-export([handle/1]).

handle(Input) -> midgard:serve(Input, fun handle_request/1).

handle_request(#midgard_request{method = <<"GET">>, path = <<"/">>}) ->
    #midgard_response{status = 200, body = <<"Hello Joe!">>};
handle_request(_Request) ->
    #midgard_response{status = 404, body = <<"Not found\n">>}.
```

`midgard:serve/2` decodes the `midgard.bytes.v1` request frame, calls your handler, and encodes the response. Malformed frames receive a 400 response. `midgard:decode_request/1` and `midgard:encode_response/1` are also available if you want to own the entrypoint yourself. The package does not provide an HTTP server or router; routes and application behavior stay in your worker.

See the [Erlang worker example](https://github.com/leostera/midgard/tree/main/examples/erlang_worker) and [Erlang project guide](https://github.com/leostera/midgard/blob/main/docs/erlang-projects.md).
