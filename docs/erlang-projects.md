# Erlang workers

Bring your Erlang worker to Midgard through a mixed Mix project or a standalone rebar3 application. Packer collects its compiled BEAMs and dependencies into a versioned artifact, preserving their original module names. Write a binary entrypoint in Erlang, or call Erlang modules from an Elixir `Midgard.Worker` handler. The Midgard Erlang library provides framework-level response types and `midgard.bytes.v1` encoding; route matching and response content stay in your Erlang worker.

## Mixed Mix projects

Put Erlang sources in `src/**/*.erl` and Elixir sources in `lib/**/*.ex`. Run `mix packer.pack` (with `packer: [entry: YourWorker]`) or `mix midgard.build` (with a `midgard.config.exs`). The worker and its Erlang helpers are packaged together. [MixedWorker](../examples/mixed_worker/README.md) demonstrates this; the [to-do example](../examples/todo/README.md) lets you try an Elixir/Erlang worker with a browser UI on ordinary OTP.

## Standalone rebar3 projects

Install rebar3 and the Packer/Midgard CLI Mix archives, then from the Midgard checkout:

```sh
mix archive.install hex midgard_packer --force
mix archive.install hex midgard_cli --force
(cd examples/erlang_worker && rebar3 midgard pack)
```

The `rebar3_midgard` plugin runs the ordinary Rebar3 compile provider, then delegates packaging to the shared Packer backend. The lower-level `mix packer.pack --project ...` command remains available for scripts.

Export the named arity-one function to accept and return bounded binaries. The [fixture](../examples/erlang_worker/README.md) parses the HTTP-shaped `midgard.bytes.v1` wire format, uses the Midgard response type, and implements `GET /hello` and `GET /hello/:name` in application code. Packer reads compiled `.app` metadata to collect one application and its dependencies. Checkout dependency versions are recorded but not lockfile-pinned.

## Runtime status

Use `mix packer.inspect --target current-core` to see static blockers before deploying. `mix midgard.deploy --artifact examples/erlang_worker/erlang_worker.midgard` verifies and admits the full dependency group, then returns an immutable route. Open that route with `/hello` or `/hello/joe` appended: the host forwards the HTTP-shaped binary request to the Erlang Isolate and returns the status/body it produces as `text/plain`. See the [fixture](../examples/erlang_worker/README.md) for a live example. This does not grant OTP services such as `gen_server` inside libbeam; successful execution of this example is not proof that another dependency closure is supported. The lower-level `raw.bytes.v1` contract remains available to workers that intentionally want opaque binary input/output instead.
