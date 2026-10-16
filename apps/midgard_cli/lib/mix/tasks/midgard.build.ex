defmodule Mix.Tasks.Midgard.Build do
  use Mix.Task
  # The archive loads before project dependencies; Packer is supplied by the
  # generated worker project after `mix deps.get`, not bundled in the archive.
  @compile {:no_warn_undefined, [Packer, Packer.Profile]}

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

    unless Code.ensure_loaded?(Packer) and Code.ensure_loaded?(Packer.Profile) do
      Mix.raise("Add the Packer dependency and run mix deps.get before building")
    end

    with {:ok, config} <- Midgard.CLI.Config.load() do
      Mix.Task.run("compile")
      output = options[:output] || "#{Mix.Project.config()[:app]}.midgard"

      with {:ok, path} <-
             Packer.pack(
               entry: Midgard.CLI.Config.entry(config),
               output: output,
               runtime_closure: true
             ),
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
