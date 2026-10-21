# Midgard Elixir SDK

Build Elixir workers with `Midgard.Worker`, typed request and response structs, and the `midgard.bytes.v1` binary entrypoint. Your worker defines its own routes and response behavior; the SDK handles the framework boundary.

> Midgard is a tech demo. Elixir workers require OTP 29 and the latest Elixir (`main`) at the runtime's pinned revision; see the [toolchain instructions](https://github.com/leostera/midgard#elixir).

## Install

Add Midgard to your worker project's dependencies:

```elixir
{:midgard, "~> 0.3"}
```

For local builds, tests, and artifact packaging, add Packer as a development dependency:

```elixir
{:packer, "~> 0.3", hex: "midgard_packer", only: [:dev, :test], runtime: false}
```

Install the Mix task archive separately with `mix archive.install hex midgard_cli`.

## Write a worker

```elixir
defmodule HelloWorker do
  use Midgard.Worker

  @impl true
  def handle_request(%Midgard.Request{method: "GET", path: "/hello"}),
    do: {200, "Hello!\n"}

  def handle_request(_request), do: {404, "Not found\n"}
end
```

`Midgard.Worker` exposes the binary entrypoint expected by the artifact contract and delegates application behavior to `handle_request/1`. See the [worker API guide](https://github.com/leostera/midgard/blob/main/docs/worker-request-api.md) and [Elixir worker example](https://github.com/leostera/midgard/blob/main/examples/hello_worker/README.md).
