defmodule Mix.Tasks.Packer.Pack do
  use Mix.Task

  @shortdoc "Compile and package exact-name BEAMs into <app>.midgard/"
  @moduledoc """
  Compile the current Mix project (`packer: [entry: MyWorker]` in mix.exs),
  or a single-app rebar3 project with `--project DIR`, or a Gleam Erlang
  project with `--project DIR --gleam`. Non-Mix builds require an entry module,
  binary arity-one `--function` and versioned `--protocol`;
  `--rebar3 PATH` or `--gleam-bin PATH` selects a local executable. `--output DIR` overrides the
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
          rebar3: :string,
          gleam: :boolean,
          gleam_bin: :string
        ]
      )

    if positional != [] or invalid != [],
      do:
        Mix.raise(
          "Usage: mix packer.pack [--project DIR] [--gleam] --entry MODULE [--function NAME] [--protocol ID] [--rebar3 PATH | --gleam-bin PATH] [--output DIR]"
        )

    if (options[:gleam] == true and is_nil(options[:project])) or
         (options[:gleam] == true and not is_nil(options[:rebar3])) or
         (not is_nil(options[:gleam_bin]) and options[:gleam] != true) do
      Mix.raise("--gleam requires --project and cannot be combined with --rebar3")
    end

    unless options[:project], do: Mix.Task.run("compile")
    entry = options[:entry] || (Mix.Project.config()[:packer] || [])[:entry]

    pack_options =
      [
        entry: entry,
        project: options[:project],
        function: options[:function],
        protocol: options[:protocol],
        rebar3: options[:rebar3],
        gleam: options[:gleam],
        gleam_bin: options[:gleam_bin],
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
