defmodule Mix.Tasks.Packer.Pack do
  use Mix.Task

  @shortdoc "Compile and package exact-name BEAMs into <app>.midgard/"
  @moduledoc """
  Compile the current Mix project (`packer: [entry: MyWorker]` in mix.exs),
  or a single-app rebar3 project with `--project DIR`. The rebar3 entry module,
  binary arity-one `--function` and versioned `--protocol` are required;
  `--rebar3 PATH` selects a local executable. `--output DIR` overrides the
  default output. This trusted-local command never deploys or invokes libbeam.
  """

  @impl true
  def run(args) do
    {options, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          output: :string,
          entry: :string,
          function: :string,
          protocol: :string,
          project: :string,
          rebar3: :string
        ]
      )

    if positional != [] or invalid != [],
      do:
        Mix.raise(
          "Usage: mix packer.pack [--project REBAR3_DIR] --entry MODULE [--function NAME] [--protocol ID] [--rebar3 PATH] [--output DIR]"
        )

    unless options[:project], do: Mix.Task.run("compile")
    entry = options[:entry] || (Mix.Project.config()[:packer] || [])[:entry]

    pack_options =
      [
        entry: entry,
        project: options[:project],
        function: options[:function],
        protocol: options[:protocol],
        rebar3: options[:rebar3],
        output: options[:output]
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    with {:ok, output} <- Packer.pack(pack_options),
         {:ok, report} <- Packer.Profile.report(output) do
      Mix.shell().info("Packed #{output}\n#{Packer.Profile.summary(report)}")
    else
      {:error, reason} -> Mix.raise("Packer failed: #{reason}")
    end
  end
end
