defmodule Midgard.MixProject do
  use Mix.Project

  def project do
    [
      app: :midgard,
      version: "0.3.0",
      elixir: "~> 1.19",
      description: "Elixir worker API for Midgard",
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/leostera/midgard"}
      ],
      deps: []
    ]
  end
end
