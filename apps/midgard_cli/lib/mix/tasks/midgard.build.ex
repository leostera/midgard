defmodule Mix.Tasks.Midgard.Build do
  use Mix.Task

  @shortdoc "Builds and verifies a provisional libbeam-targeted BEAM artifact"
  @moduledoc """
  Reads the required `midgard.config.exs`, compiles the worker and dependency
  BEAMs on the developer machine, and writes `<app>.midgard/`. The generated
  artifact has not been loaded or executed by libbeam. Pass `--output DIR` to
  choose an output directory.
  """

  @impl true
  def run(args) do
    {options, positional, invalid} = OptionParser.parse(args, strict: [output: :string])

    if positional != [] or invalid != [], do: Mix.raise("Usage: mix midgard.build [--output DIR]")

    with {:ok, config} <- Midgard.CLI.Config.load() do
      Mix.Task.run("compile")
      output = options[:output] || "#{Mix.Project.config()[:app]}.midgard"

      with {:ok, path} <- Packer.pack(entry: Midgard.CLI.Config.entry(config), output: output),
           {:ok, report} <- Packer.Profile.report(path) do
        Mix.shell().info("Built #{path}\n#{Packer.Profile.summary(report)}")
      else
        {:error, reason} -> Mix.raise("Midgard build failed: #{reason}")
      end
    else
      {:error, reason} -> Mix.raise("Midgard build failed: #{reason}")
    end
  end
end
