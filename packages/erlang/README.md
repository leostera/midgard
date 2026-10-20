# Midgard Erlang SDK

Build Erlang workers with framework request/response records and a small response encoder. The SDK gives your worker a consistent `midgard.bytes.v1` response format; your application still owns its routes and response behavior.

## Install

Add the SDK to `rebar.config`:

```erlang
{deps, [{midgard, {pkg, midgard_erlang, "0.2.0"}}]}.
```

The Hex package is named `midgard_erlang`; the Erlang application and module remain `midgard`.

## Use

Include the records and return a response from your worker's entry function:

```erlang
-include_lib("midgard/include/midgard.hrl").

handle_request(#midgard_request{method = <<"GET">>, path = <<"/hello">>}) ->
    #midgard_response{status = 200, body = <<"Hello!\n">>};
handle_request(_Request) ->
    #midgard_response{status = 404, body = <<"Not found\n">>}.
```

Encode a response with `midgard:encode_response/1`. It validates the status and body bounds, then returns the protocol frame. The package does not provide an HTTP server or router; keep those decisions and application behavior in your worker.

See the [Erlang worker example](../../examples/erlang_worker/README.md) and [Erlang project guide](../../docs/erlang-projects.md).
