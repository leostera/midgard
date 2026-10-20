defmodule Packer.MixProject do
  use Mix.Project

  def project do
    unless Code.ensure_loaded?(:json),
      do: Mix.raise("Packer requires OTP 27+ with the :json module")

    [
      app: :packer,
      version: "0.1.0",
      elixir: "~> 1.19",
      description: "Versioned BEAM artifact assembler and static verifier",
      package: [
        name: "midgard_packer",
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/leostera/midgard"}
      ],
      deps: []
    ]
  end

  def application, do: [extra_applications: [:crypto]]
end
