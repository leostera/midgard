defmodule MixedWorker.MixProject do
  use Mix.Project

  def project do
    [
      app: :mixed_worker,
      version: "0.1.0",
      elixir: "~> 1.21.0-dev",
      packer: [entry: MixedWorker],
      deps: [
        {:packer,
         path: Path.expand("../../apps/packer", __DIR__), only: [:dev, :test], runtime: false}
      ]
    ]
  end
end
