defmodule Midgard.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      aliases: [
        "midgard.test": fn arguments ->
          Mix.Task.run("compile")
          Mix.Task.load_all()
          Mix.Tasks.Midgard.Test.run(arguments)
        end
      ]
    ]
  end
end
