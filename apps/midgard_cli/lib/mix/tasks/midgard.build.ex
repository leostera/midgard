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
  choose an output directory. The artifact is tree shaken: only functions
  reachable from the worker's entrypoint ship. `--no-shake` ships the whole
  runtime closure instead.
  """

  @impl true
  def run(args) do
    {options, positional, invalid} =
      OptionParser.parse(args, strict: [output: :string, shake: :boolean])

    if positional != [] or invalid != [],
      do: Mix.raise("Usage: mix midgard.build [--output DIR] [--no-shake]")

    with {:ok, config} <- Midgard.CLI.Config.load() do
      Mix.Task.run("compile")

      unless Code.ensure_loaded?(Packer) and Code.ensure_loaded?(Packer.Profile) do
        Mix.raise("Add the Packer dependency and run mix deps.get before building")
      end

      output = options[:output] || "#{Mix.Project.config()[:app]}.midgard"

      with {:ok, path} <-
             Packer.pack(
               entry: Midgard.CLI.Config.entry(config),
               output: output,
               runtime_closure: true,
               shake: Keyword.get(options, :shake, true)
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
