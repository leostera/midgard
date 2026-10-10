defmodule Mix.Tasks.Midgard.New do
  use Mix.Task

  @shortdoc "Creates a new Midgard worker project"
  @moduledoc """
  Creates a Midgard worker project with source, tests, `midgard.config.exs`,
  and development-time Packer and CLI dependencies. Building runs under the
  local developer's authority; no Isolate or deployment host is present.

      mix midgard.new hello_worker
      mix midgard.new hello_worker --path /path/to/hello_worker

  Until the packages are published, generated dependencies point to the local
  Midgard checkout. Override its location with `--midgard-root PATH`.
  Install the CLI as a Mix archive to use this task outside a project.
  """

  @impl true
  def run(args) do
    {options, positional, invalid} =
      OptionParser.parse(args, strict: [path: :string, midgard_root: :string])

    case {positional, invalid} do
      {[name], []} ->
        destination = options[:path] || name
        root = options[:midgard_root] || Midgard.CLI.Generator.default_root()

        case Midgard.CLI.Generator.generate(name, destination, root) do
          {:ok, path} ->
            Mix.shell().info(
              "Created #{path}\nNext: cd #{path} && mix deps.get && mix test && mix midgard.build"
            )

          {:error, reason} ->
            Mix.raise("midgard.new: #{reason}")
        end

      _ ->
        Mix.raise("Usage: mix midgard.new NAME [--path DIR] [--midgard-root PATH]")
    end
  end
end
