# Erlang workers

Bring your Erlang worker to Midgard through a mixed Mix project or a standalone rebar3 application. Packer collects its compiled BEAMs and dependencies into a versioned artifact, preserving their original module names. Write a binary entrypoint in Erlang, or call Erlang modules from an Elixir `Midgard.Worker` handler. The `midgard_erlang` SDK provides request and response records, `midgard.bytes.v1` decoding and encoding, and `midgard:serve/2`; route matching and response content stay in your Erlang worker.

## Mixed Mix projects

Put Erlang sources in `src/**/*.erl` and Elixir sources in `lib/**/*.ex`. Run `mix packer.pack` (with `packer: [entry: YourWorker]`) or `mix midgard.build` (with a `midgard.config.exs`). The worker and its Erlang helpers are packaged together. [MixedWorker](../examples/mixed_worker/README.md) demonstrates this; the [to-do example](../examples/todo/README.md) lets you try an Elixir/Erlang worker with a browser UI on ordinary OTP.

## Standalone rebar3 projects

Install Rebar3, Elixir, and Mix, then install the shared Packer and Midgard CLI archives once:

```sh
mix archive.install hex midgard_packer --force
mix archive.install hex midgard_cli --force
(cd examples/erlang_worker && rebar3 midgard pack)
```

The `rebar3_midgard` plugin runs the ordinary Rebar3 compile provider, then delegates packaging to the shared Packer backend. The lower-level `mix packer.pack --project ...` command remains available for scripts.

Export the named arity-one function to accept and return bounded binaries. The simplest entrypoint is `handle(Input) -> midgard:serve(Input, fun handle_request/1).`, which decodes the `midgard.bytes.v1` request into a `#midgard_request{}` and encodes the `#midgard_response{}` your handler returns. The [example](../examples/erlang_worker/README.md) implements `GET /`, `GET /hello`, and `GET /hello/:name` this way. Packer reads compiled `.app` metadata to collect one application and its dependencies. Pin the SDK and plugin versions in `rebar.config`, and commit `rebar.lock` to lock the full dependency graph.

## Runtime status

Use `mix packer.inspect --target current-core` to see static blockers before deploying. `mix midgard.deploy --artifact examples/erlang_worker/erlang_worker.midgard` verifies and admits the full dependency group, then returns an immutable route. Open that route, or append `/hello/joe`: the host forwards the HTTP-shaped binary request to the Erlang Isolate and returns the status/body it produces as `text/plain`. See the [fixture](../examples/erlang_worker/README.md) for a live example. This does not grant OTP services such as `gen_server` inside libbeam; successful execution of this example is not proof that another dependency closure is supported. The lower-level `raw.bytes.v1` contract remains available to workers that intentionally want opaque binary input/output instead.
