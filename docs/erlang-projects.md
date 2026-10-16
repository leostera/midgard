# Erlang workers

Bring your Erlang worker to Midgard through a mixed Mix project or a standalone rebar3 application. Packer collects its compiled BEAMs and dependencies into a versioned artifact, preserving their original module names. Write a binary entrypoint in Erlang, or call Erlang modules from an Elixir `Midgard.Worker` handler. We are designing the worker framework for Elixir first; standalone Erlang packaging does not depend on adopting that API.

## Mixed Mix projects

Put Erlang sources in `src/**/*.erl` and Elixir sources in `lib/**/*.ex`. Run `mix packer.pack` (with `packer: [entry: YourWorker]`) or `mix midgard.build` (with a `midgard.config.exs`). The worker and its Erlang helpers are packaged together. [MixedWorker](../examples/mixed_worker/README.md) demonstrates this; the [to-do example](../examples/todo/README.md) lets you try an Elixir/Erlang worker with a browser UI on ordinary OTP.

## Standalone rebar3 projects

Install rebar3, then from the Midgard checkout:

```sh
mix packer.pack --project examples/erlang_worker --entry erlang_worker \
  --function handle --protocol raw.bytes.v1
mix packer.inspect examples/erlang_worker/erlang_worker.midgard
```

Export the named arity-one function to accept and return bounded binaries. The [fixture](../examples/erlang_worker/README.md) echoes bytes under the declared `raw.bytes.v1` protocol; this is an application-defined byte contract, separate from the Elixir SDK's HTTP-shaped `midgard.bytes.v1`. Packer reads compiled `.app` metadata to collect one application and its dependencies. Checkout dependency versions are recorded but not lockfile-pinned.

## Runtime status

Use `mix packer.inspect --target current-core` to see static blockers before deploying. Midgard now accepts and calls standalone Erlang `raw.bytes.v1` workers: `mix midgard.deploy --artifact examples/erlang_worker/erlang_worker.midgard` verifies and admits the full dependency group, then returns an immutable route. Send binary bytes with `POST` to that route root; the response is raw `application/octet-stream`, not an Elixir SDK HTTP response. Opening the route root in a browser uses Midgard's separate `GET` text preview: it sends `hello` into the same raw-byte Isolate and renders the result as text; `?input=your-text` selects a small UTF-8 preview input. See the [fixture](../examples/erlang_worker/README.md) for a live example. This does not supply an Erlang request framework or grant OTP services such as `gen_server` inside libbeam; successful execution of one echo fixture is not proof that another dependency closure is supported.
