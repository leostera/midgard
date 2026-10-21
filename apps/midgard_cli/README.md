# Midgard CLI

Scaffold Elixir worker projects and add the local build-and-deploy commands. The CLI helps turn a worker project into a public worker URL; compilation and tests run on your development machine.

> Midgard is a tech demo. Elixir workers require OTP 29 and the latest Elixir (`main`) at the runtime's pinned revision; see the [toolchain instructions](https://github.com/leostera/midgard#elixir).

## Start a project

Install the CLI archive, then scaffold a project:

```sh
mix archive.install hex midgard_cli --force
mix midgard.new hello_worker
cd hello_worker
mix deps.get
mix test
```

The generated project includes an example worker, tests, and build configuration. Its Packer dependency builds the compiled project into a `.midgard` package.

## Build and deploy

```sh
mix midgard.build
mix midgard.deploy
```

`mix midgard.build` creates a package locally. `mix midgard.deploy` builds and uploads it, then prints the worker URL. To deploy an artifact produced by another toolchain, pass `--artifact path/to/worker.midgard`; Rebar3 workers use `rebar3 midgard deploy` for that workflow.

The CLI supplies Mix tasks, not a runtime or web server. Worker code and its dependencies execute with your local development authority during compilation and tests. See the [Elixir worker example](https://github.com/leostera/midgard/blob/main/examples/hello_worker/README.md) and [deployment guide](https://github.com/leostera/midgard/blob/main/docs/worker-request-api.md).

The generated project uses the published `midgard` SDK and `midgard_packer` build backend as Hex dependencies.
