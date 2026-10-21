defmodule Midgard.CLI.MixProject do
  use Mix.Project

  def project do
    [
      app: :midgard_cli,
      version: "0.3.0",
      elixir: "~> 1.19",
      description: "Mix tasks for creating, building, and deploying Midgard workers",
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/leostera/midgard"}
      ],
      # A sparse Git archive install contains only this app. In a worker
      # project Packer is supplied by that project's own Mix dependencies.
      deps:
        if(Mix.Project.parent_umbrella_project_file(),
          do: [{:packer, in_umbrella: true}],
          else: []
        )
    ]
  end

  def application, do: [extra_applications: [:inets, :ssl, :public_key]]
end
