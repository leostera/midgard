# Midgard

**Serverless Elixir, Erlang, and Gleam.** Write a request handler, deploy it from your machine, and get a public URL. Every deployment gets its own immutable URL. Try it at [midgard.leostera.dev](https://midgard.leostera.dev).

> [!IMPORTANT]
> **Midgard is a tech demo.** It requires **OTP 29**. Elixir workers also need the latest Elixir (`main`) built at the runtime's pinned revision. Deployments are public and anonymous; see [Before you try it](#before-you-try-it).

Workers run on [libbeam](https://github.com/leostera/libbeam). Midgard builds your worker locally, packages its exact BEAM modules and compiled dependencies with a checksummed manifest, and uploads that shipment. The platform verifies the shipment and admits the whole BEAM group to libbeam before it serves any requests.

## Quickstart

Each quickstart ends with a worker that answers `GET /` with `Hello Joe!`. See them running: [Elixir](https://elixir-worker-55c7a1ccc4fd91b9.midgard.leostera.dev/), [Erlang](https://erlang-worker-b55793b2b7009042.midgard.leostera.dev/), [Gleam](https://gleam-worker-553f63ed27a67575.midgard.leostera.dev/).

### Elixir

Elixir workers must be compiled by the same Elixir revision the runtime uses. Build it once:

```sh
git clone https://github.com/elixir-lang/elixir.git /tmp/midgard-elixir
git -C /tmp/midgard-elixir checkout 13299af2b91a6aff7e430f25849f586c02b3231f
make -C /tmp/midgard-elixir compile install PREFIX=/tmp/midgard-toolchain
export PATH="/tmp/midgard-toolchain/bin:$PATH"
```

Then scaffold, test, and deploy a worker:

```sh
mix archive.install hex midgard_cli --force
mix midgard.new hello_worker
cd hello_worker && mix deps.get
mix test
mix midgard.deploy
```

The generated `lib/hello_worker.ex` uses the Elixir SDK:

```elixir
defmodule HelloWorker do
  use Midgard.Worker

  @impl true
  def handle_request(%Midgard.Request{method: "GET", path: "/"}) do
    {200, "Hello Joe!"}
  end

  # ...plus /hello and /hello/:name routes
end
```

The deploy prints your **Worker URL**:

```sh
curl https://hello-worker-0123456789abcdef.midgard.leostera.dev/
```

### Gleam

You need Gleam, Elixir, and OTP 29. Gleam can't run external build tools yet, so packaging and deploys use Midgard's Mix archives:

```sh
mix archive.install hex midgard_packer --force
mix archive.install hex midgard_cli --force

gleam new hello_worker && cd hello_worker
gleam remove gleam_stdlib
gleam add midgard_gleam@0.4.0
```

Removing `gleam_stdlib` keeps the shipment to your code plus the SDK. Replace `src/hello_worker.gleam` with:

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

Then build and deploy:

```sh
mix packer.pack --project . --gleam \
  --entry hello_worker --function handle --protocol midgard.bytes.v1
mix midgard.deploy --artifact hello_worker.midgard
```

### Erlang

You need Rebar3, Elixir, and OTP 29. The `rebar3_midgard` plugin hands packaging and deploys to Midgard's Mix archives:

```sh
mix archive.install hex midgard_packer --force
mix archive.install hex midgard_cli --force

rebar3 new lib hello_worker && cd hello_worker
cat > rebar.config <<'EOF'
{erl_opts, [debug_info]}.
{deps, [{midgard, "0.4.0", {pkg, midgard_erlang}}]}.
{project_plugins, [{rebar3_midgard, "0.4.0"}]}.
{midgard, [{entry, hello_worker}, {function, handle},
           {protocol, "midgard.bytes.v1"}]}.
EOF
```

Replace `src/hello_worker.erl` with:

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

Then deploy:

```sh
rebar3 midgard deploy
```

## Before you try it

- **Bleeding-edge toolchain.** Requires OTP 29. Elixir workers also need Elixir `main` built at the runtime's pinned revision; Packer rejects other Elixir builds before uploading.
- **Public and anonymous.** There are no accounts. Anyone with a worker's URL can call it, so don't deploy secrets or private code.
- **Immutable deploys.** Every deploy gets a new URL. You can't update or delete an existing deployment.
- **Small, shared limits.** Uploads are capped at 24 MB, and uploads and requests are rate-limited. Demos may be cleared at any time.
- **Not a full OTP node.** Workers run on [libbeam](https://github.com/leostera/libbeam), so many libraries won't run yet. Each shipment is checked before it's admitted, but this is not a hardened sandbox.
- **Trusted builds only.** Compilers, dependencies, and macros run on your machine with your privileges.

Found a bug or have an idea? [Open an issue](https://github.com/leostera/midgard/issues).

## Packages

All packages are published on Hex under the MIT license:

| Package | What it is |
| --- | --- |
| [`midgard`](https://hex.pm/packages/midgard) | Elixir SDK: `Midgard.Worker`, request and response structs |
| [`midgard_cli`](https://hex.pm/packages/midgard_cli) | Mix archive: `mix midgard.new` and `mix midgard.deploy` |
| [`midgard_packer`](https://hex.pm/packages/midgard_packer) | Mix archive: builds and inspects `.midgard` shipments for Mix, Rebar3, and Gleam projects |
| [`midgard_erlang`](https://hex.pm/packages/midgard_erlang) | Erlang SDK: `midgard:serve/2`, request and response records |
| [`midgard_gleam`](https://hex.pm/packages/midgard_gleam) | Gleam SDK: `midgard.serve`, `Request` and `Response` types |
| [`rebar3_midgard`](https://hex.pm/packages/rebar3_midgard) | Rebar3 plugin: `rebar3 midgard pack`, `inspect`, and `deploy` |

## Examples and guides

- [Elixir worker](examples/hello_worker/README.md), [mixed Elixir/Erlang worker](examples/mixed_worker/README.md), and a [to-do app](examples/todo/README.md) behind a local HTTP UI
- [Erlang worker](examples/erlang_worker/README.md) and [Gleam worker](examples/gleam_worker/README.md)
- [Elixir worker API](docs/worker-request-api.md): request fields and the response contract
- [Build and inspect shipments](docs/packer.md) for each project type
- [Erlang projects](docs/erlang-projects.md): Rebar3 and mixed Mix projects
- [Local platform setup](apps/midgard_platform/README.md): run the platform and a native libbeam host yourself, then deploy with `--endpoint http://127.0.0.1:4000`
- [RFD0002](docs/rfds/RFD0002-artifact-and-worker-contract.md): the artifact format and verifier invariants

## How deployment works

`mix midgard.deploy` builds the worker's BEAM dependency closure on your machine, [tree-shakes](docs/packer.md#tree-shaking) it down to the functions the worker can reach, and uploads it through a rate-limited edge Worker. The platform verifies the manifest and checksums, admits the whole group to libbeam, and only then gives it a public URL. The edge stores the exact shipment and re-verifies and re-admits it after a restart. There is no server-side compilation. `mix packer.inspect --target current-core` is a conservative static check, not proof that a worker will run.

## License

Midgard is licensed under the [MIT License](LICENSE).
