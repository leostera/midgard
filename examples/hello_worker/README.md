# HelloWorker (provisional Midgard BEAM artifact example)

Two local modules (`HelloWorker` and `HelloWorker.Greeter`) plus the pure-Elixir Jason dependency demonstrate compiled BEAM packaging. `use Midgard.Worker` exports the binary `__midgard_call__/1` wrapper around `handle_request(%Midgard.Request{})`. Request handling and wrapper tests run on ordinary OTP, **not** in libbeam.

```sh
mix deps.get
mix test
mix midgard.build                   # uses midgard.config.exs
mix packer.pack                     # uses packer: [entry: HelloWorker] in mix.exs
mix packer.inspect hello_worker.midgard
mix packer.inspect hello_worker.midgard --target current-core  # expected refusal
```

The inspectable `hello_worker.midgard/` contains `manifest.json`, exact-name local BEAMs, Jason BEAMs and the Midgard SDK BEAMs; each module is hashed and assigned to a dependency/application. The entrypoint is `Elixir.HelloWorker:__midgard_call__/1`, protocol `midgard.bytes.v1`. The manifest states `execution: not_verified`. `%Midgard.Request{}`, Jason and Elixir's runtime imports use instructions/modules unsupported by today's limited libbeam core. The current-core diagnostic **must fail**; neither command deploys or starts an Isolate. There is no local Phoenix service. Do not treat a valid artifact as a secure or executable tenant.

Routes handled in ordinary OTP tests: `GET /hello?name=...`, `POST /json`, `POST /echo` (binary), and 404 for unknown requests. The standalone project uses local checkout paths in `mix.exs`, not published packages.
