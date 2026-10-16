defmodule LibbeamElixir.MixProject do
  use Mix.Project

  def project do
    [
      app: :libbeam_elixir,
      version: "0.1.0-dev",
      elixir: "~> 1.19",
      description: "Supervised Port bindings for libbeam Isolates",
      deps: []
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
