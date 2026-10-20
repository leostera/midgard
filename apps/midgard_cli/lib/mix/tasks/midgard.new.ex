defmodule Mix.Tasks.Midgard.New do
  use Mix.Task

  @shortdoc "Creates a new Midgard worker project"
  @moduledoc """
  Creates a Midgard worker project with source, tests, `midgard.config.exs`,
  and development-time Packer and CLI dependencies. Building runs under the
  local developer's authority; no Isolate or deployment host is present.

      mix midgard.new hello_worker
      mix midgard.new hello_worker --path /path/to/hello_worker

  An archive installed from GitHub generates projects pinned to the archive's
  exact Git revision. Use `--midgard-root PATH` to work against a local checkout
  instead (including uncommitted development changes).
  """

  @impl true
  def run(args) do
    {options, positional, invalid} =
      OptionParser.parse(args, strict: [path: :string, midgard_root: :string])

    case {positional, invalid} do
      {[name], []} ->
        destination = options[:path] || name

        created =
          case options[:midgard_root] do
            nil ->
              Midgard.CLI.Generator.generate_from_archive(name, destination)

            root ->
              Midgard.CLI.Generator.generate(name, destination, root)
          end

        case created do
          {:ok, path} ->
            Mix.shell().info(
              "Created #{path}\nNext: cd #{path} && mix deps.get && mix test && mix midgard.deploy"
            )

          {:error, reason} ->
            Mix.raise("midgard.new: #{reason}")
        end

      _ ->
        Mix.raise("Usage: mix midgard.new NAME [--path DIR] [--midgard-root PATH]")
    end
  end
end
