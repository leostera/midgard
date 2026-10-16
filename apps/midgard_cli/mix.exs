defmodule Midgard.CLI.MixProject do
  use Mix.Project

  def project do
    [
      app: :midgard_cli,
      version: "0.1.0",
      elixir: "~> 1.19",
      description: "Midgard worker generator and provisional BEAM artifact build tasks",
      # A sparse Git archive install contains only this app. In a worker
      # project Packer is supplied by that project's own Mix dependencies.
      deps:
        if(File.dir?(Path.expand("../packer", __DIR__)),
          do: [{:packer, in_umbrella: true}],
          else: []
        )
    ]
  end

  def application, do: [extra_applications: [:inets, :ssl, :public_key]]
end
