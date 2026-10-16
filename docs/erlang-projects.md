# Erlang workers

Bring your Erlang worker to Midgard through a mixed Mix project or a standalone rebar3 application. Packer collects its compiled BEAMs and dependencies into a versioned artifact, preserving their original module names. Write a binary entrypoint in Erlang, or call Erlang modules from an Elixir `Midgard.Worker` handler. We are designing the worker framework for Elixir first; standalone Erlang packaging does not depend on adopting that API.

## Mixed Mix projects

Put Erlang sources in `src/**/*.erl` and Elixir sources in `lib/**/*.ex`. Run `mix packer.pack` (with `packer: [entry: YourWorker]`) or `mix midgard.build` (with a `midgard.config.exs`). The worker and its Erlang helpers are packaged together. [MixedWorker](../examples/mixed_worker/README.md) demonstrates this; the [to-do example](../examples/todo/README.md) lets you try an Elixir/Erlang worker with a browser UI on ordinary OTP.

## Standalone rebar3 projects

Install rebar3, then from the Midgard checkout:

```sh
mix packer.pack --project examples/erlang_worker --entry erlang_worker \
  --function handle --protocol midgard.bytes.v1
mix packer.inspect examples/erlang_worker/erlang_worker.midgard
```

Export the named arity-one function to accept and return bounded binaries. The [fixture](../examples/erlang_worker/README.md) parses the HTTP-shaped `midgard.bytes.v1` wire format and implements `GET /hello` and `GET /hello/:name`, just like an Elixir SDK worker. Packer reads compiled `.app` metadata to collect one application and its dependencies. Checkout dependency versions are recorded but not lockfile-pinned.

## Runtime status

Use `mix packer.inspect --target current-core` to see static blockers before deploying. `mix midgard.deploy --artifact examples/erlang_worker/erlang_worker.midgard` verifies and admits the full dependency group, then returns an immutable route. Open that route with `/hello` or `/hello/joe` appended: the host forwards the HTTP-shaped binary request to the Erlang Isolate and returns the status/body it produces as `text/plain`. See the [fixture](../examples/erlang_worker/README.md) for a live example. This does not grant OTP services such as `gen_server` inside libbeam; successful execution of this example is not proof that another dependency closure is supported. The lower-level `raw.bytes.v1` contract remains available to workers that intentionally want opaque binary input/output instead.
