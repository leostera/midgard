defmodule TodoWeb.MixProject do
  use Mix.Project

  def project do
    [
      app: :todo_web,
      version: "0.1.0",
      elixir: "~> 1.19",
      deps: [
        {:todo_worker, path: "../worker"},
        {:bandit, "~> 1.12"},
        {:plug, "~> 1.20"}
      ]
    ]
  end

  def application do
    [mod: {TodoWeb.Application, []}, extra_applications: [:logger, :crypto]]
  end
end
