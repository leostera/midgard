defmodule MidgardPlatform.MixProject do
  use Mix.Project

  def project do
    [
      app: :midgard_platform,
      version: "0.1.0-dev",
      elixir: "~> 1.19",
      description: "Isolate deployment and binary dispatch on libbeam_elixir",
      deps: [
        {:libbeam_elixir, in_umbrella: true},
        {:midgard, in_umbrella: true},
        {:bandit, "~> 1.12"},
        {:plug, "~> 1.18"}
      ]
    ]
  end

  def application do
    [extra_applications: [:crypto], mod: {Midgard.Platform.Application, []}]
  end
end
