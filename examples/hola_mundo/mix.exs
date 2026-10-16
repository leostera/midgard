defmodule HolaMundo.MixProject do
  use Mix.Project

  def project do
    [
      app: :hola_mundo,
      version: "0.1.0",
      elixir: "~> 1.21.0-dev",
      packer: [entry: HolaMundo],
      deps: [
        {:midgard,
         git: "https://github.com/leostera/midgard.git",
         ref: "55c3c12c592909a05d67b2a7bdb09c03606e261e",
         subdir: "apps/midgard"},
        {:packer,
         git: "https://github.com/leostera/midgard.git",
         ref: "55c3c12c592909a05d67b2a7bdb09c03606e261e",
         subdir: "apps/packer",
         only: [:dev, :test],
         runtime: false}
      ]
    ]
  end
end
