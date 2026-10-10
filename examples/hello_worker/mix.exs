defmodule HelloWorker.MixProject do
  use Mix.Project

  def project do
    [
      app: :hello_worker,
      version: "0.1.0",
      elixir: "~> 1.19",
      packer: [entry: HelloWorker],
      deps: [
        {:midgard, path: "../../apps/midgard"},
        {:jason, "~> 1.4"},
        {:packer, path: "../../apps/packer", only: [:dev, :test], runtime: false},
        {:midgard_cli, path: "../../apps/midgard_cli", only: [:dev, :test], runtime: false}
      ]
    ]
  end
end
