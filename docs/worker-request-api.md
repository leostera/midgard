# Write an Elixir worker

The first Midgard framework API is for **Elixir**. Use `Midgard.Worker` to write an ordinary Elixir request handler. The SDK turns that handler into a versioned binary entrypoint, so Packer can ship it with your dependencies as a worker artifact. Implement `handle_request/1` with a `%Midgard.Request{}` and return `{status, body}`:

```elixir
defmodule MyWorker do
  use Midgard.Worker

  @impl true
  def handle_request(%Midgard.Request{method: "GET", path: "/hello"}),
    do: {200, "Hello!\n"}

  def handle_request(_request), do: {404, "Not found\n"}
end
```

The [HelloWorker example](../examples/hello_worker/README.md) shows a complete handler with tests on ordinary Elixir/OTP and a build command. `Midgard.Request` is an Elixir struct with these fields:

| Request field | Accepted value |
| --- | --- |
| `method` | Uppercase ASCII, 1–16 bytes |
| `path` | Starts with `/`, up to 2048 bytes |
| `query_string` | Raw bytes without `?`, up to 2048 bytes |
| `headers` | Up to 32 ordered, lowercase-name `{name, value}` pairs; duplicate names are preserved, CR/LF values rejected |
| `body` | Complete binary, up to 32 KiB |

The generated `__midgard_call__/1` entrypoint speaks `midgard.bytes.v1` with frames of at most 64 KiB. Responses carry a status (100–599) and a complete binary body. The wrapper returns 400 for a malformed request frame and 500 for an invalid handler response or ordinary exception when it can execute. This version keeps the contract small: it does not encode response headers, streams, or implicit JSON.

## Scope and runtime status

`Midgard.Request`, `Midgard.Worker`, and `handle_request/1` are Elixir-facing; they are **not** a required in-memory API for Erlang or Gleam. The language-native packages in [`packages/erlang`](../packages/erlang) and [`packages/gleam`](../packages/gleam) provide typed response values and `midgard.bytes.v1` response encoding. Workers still own request parsing, route matching, and response content in their own language. Example-specific behavior such as greeting a user belongs in the worker—not the Midgard framework library. These packages can evolve their public types and conventions without changing the existing Elixir handler.

You can develop and test this API on ordinary OTP and build an inspectable artifact today. The Elixir worker profile has not been executed as a whole in libbeam, and Midgard does not yet provide an HTTP/Isolate host or storage/network bindings. A future host will need its own header policy, deadlines, admission, and error handling. For the exact frame format and implementation invariants, see [RFD0002](rfds/RFD0002-artifact-and-worker-contract.md).
