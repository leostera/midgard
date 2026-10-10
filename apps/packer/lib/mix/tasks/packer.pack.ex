defmodule Mix.Tasks.Packer.Pack do
  use Mix.Task

  @shortdoc "Compile and package exact-name BEAMs into <app>.midgard/"
  @moduledoc """
  Compiles the current Mix project and writes a versioned, inspectable BEAM
  directory. Set `packer: [entry: MyWorker]` in `mix.exs`, or pass `--entry`.
  Use `--output DIR` for a different destination, `--function` for another
  binary arity-one export, and `--protocol` for its wire contract. This is
  trusted local build tooling; it does not run an Isolate or deploy anything.
  """

  @impl true
  def run(args) do
    {options, positional, invalid} =
      OptionParser.parse(args,
        strict: [output: :string, entry: :string, function: :string, protocol: :string]
      )

    if positional != [] or invalid != [],
      do:
        Mix.raise(
          "Usage: mix packer.pack [--entry Elixir.MyWorker] [--function NAME] [--protocol ID] [--output DIR]"
        )

    Mix.Task.run("compile")
    entry = options[:entry] || (Mix.Project.config()[:packer] || [])[:entry]

    with {:ok, output} <-
           Packer.pack(
             entry: entry,
             function: options[:function] || "__midgard_call__",
             protocol: options[:protocol] || "midgard.bytes.v1",
             output: options[:output] || "#{Mix.Project.config()[:app]}.midgard"
           ),
         {:ok, report} <- Packer.Profile.report(output) do
      Mix.shell().info("Packed #{output}\n#{Packer.Profile.summary(report)}")
    else
      {:error, reason} -> Mix.raise("Packer failed: #{reason}")
    end
  end
end
