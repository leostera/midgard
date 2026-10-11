defmodule TodoWorker.MixProject do
  use Mix.Project

  @midgard_root Path.expand("../../..", __DIR__)

  def project do
    [
      app: :todo_worker,
      version: "0.1.0",
      elixir: "~> 1.19",
      packer: [entry: TodoWorker],
      deps: [
        {:midgard, path: Path.join(@midgard_root, "apps/midgard")},
        {:jason, "~> 1.4"},
        {:packer,
         path: Path.join(@midgard_root, "apps/packer"), only: [:dev, :test], runtime: false},
        {:midgard_cli,
         path: Path.join(@midgard_root, "apps/midgard_cli"), only: [:dev, :test], runtime: false}
      ]
    ]
  end
end
