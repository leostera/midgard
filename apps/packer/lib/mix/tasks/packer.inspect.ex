defmodule Mix.Tasks.Packer.Inspect do
  use Mix.Task

  @shortdoc "Verify an artifact and report provisional libbeam compatibility"
  @moduledoc """
  `mix packer.inspect PATH` validates manifest, hashes, BEAM identities,
  ownership and entrypoint without loading or executing guest code.
  `--target current-core` fails if known unsupported operations or unresolved
  imports remain. No mode claims real Isolate execution.
  """

  @impl true
  def run(args) do
    {options, positional, invalid} = OptionParser.parse(args, strict: [target: :string])

    if invalid != [] or length(positional) != 1 or options[:target] not in [nil, "current-core"],
      do: Mix.raise("Usage: mix packer.inspect PATH [--target current-core]")

    [path] = positional

    with {:ok, manifest} <- Packer.Verifier.verify(path),
         {:ok, report} <- Packer.Profile.report(path) do
      Mix.shell().info(
        "Artifact #{path}: #{length(manifest["modules"])} exact-name BEAMs, entry #{manifest["entrypoint"]["module"]}"
      )

      if options[:target] == "current-core" do
        Mix.shell().info(Packer.Profile.summary(report))

        case Packer.Profile.current_core_check(path) do
          {:ok, note} -> Mix.shell().info(note)
          {:error, reason} -> Mix.raise(reason)
        end
      else
        Mix.shell().info(Packer.JSON.encode(report))
      end
    else
      {:error, reason} -> Mix.raise("Invalid artifact: #{reason}")
    end
  end
end
