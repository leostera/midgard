defmodule Midgard.CLI.MixProject do
  use Mix.Project

  def project do
    [
      app: :midgard_cli,
      version: "0.1.0",
      elixir: "~> 1.19",
      description: "Midgard worker generator and provisional BEAM artifact build tasks",
      deps: [{:packer, in_umbrella: true}]
    ]
  end
end
