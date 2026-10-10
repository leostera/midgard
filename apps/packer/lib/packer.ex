defmodule Packer do
  @moduledoc """
  Trusted build-time assembler for exact-name BEAM artifacts. This library
  never loads dependency code into an isolate or a serving VM. Compiler-side
  Mix tasks still run with the developer machine's ordinary authority.
  """

  @doc "Builds `<app>.midgard/` (or `:output`) from the current compiled Mix project."
  def pack(opts \\ []) when is_list(opts) do
    app = Keyword.get(opts, :app, Mix.Project.config()[:app])
    entry = Keyword.get(opts, :entry)
    output = Keyword.get(opts, :output, "#{app}.midgard")

    with :ok <- validate_options(app, entry, output),
         {:ok, local} <- local_modules(app),
         {:ok, dependencies} <- Packer.Dependencies.collect() do
      modules =
        Enum.map(local, fn {name, bytes} -> %{name: name, owner: to_string(app), bytes: bytes} end) ++
          for dep <- dependencies,
              {name, bytes} <- dep.beams,
              do: %{name: name, owner: dep.app, bytes: bytes}

      dep_records =
        Enum.map(dependencies, fn dep ->
          %{app: dep.app, version: dep.version, modules: Enum.map(dep.beams, &elem(&1, 0))}
        end)

      Packer.Artifact.build(output, to_string(app), module_name(entry), modules, dep_records,
        function: Keyword.get(opts, :function, "__midgard_call__"),
        protocol: Keyword.get(opts, :protocol, "midgard.bytes.v1")
      )
    end
  end

  defp validate_options(app, entry, output) do
    if is_atom(app) and app == Mix.Project.config()[:app] and
         Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, Atom.to_string(app)) and
         (is_atom(entry) or is_binary(entry)) and is_binary(output) and output != "" and
         not String.contains?(output, <<0>>) do
      :ok
    else
      {:error, "expected :app, :entry module and output directory"}
    end
  end

  defp module_name(entry) when is_atom(entry), do: Atom.to_string(entry)
  defp module_name("Elixir." <> _ = entry), do: entry
  defp module_name(entry), do: "Elixir." <> entry

  defp local_modules(app) do
    dir = Path.join([Mix.Project.build_path(), "lib", Atom.to_string(app), "ebin"])
    paths = Path.wildcard(Path.join(dir, "Elixir.*.beam")) |> Enum.sort()

    cond do
      unsupported_project_input?(dir, paths) ->
        {:error, "project has unsupported native/Erlang code or unpackaged priv resources"}

      paths == [] ->
        {:error, "no compiled project BEAMs found in #{dir}; run mix compile"}

      true ->
        Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
          case File.read(path) do
            {:ok, bytes} -> {:cont, {:ok, [{Path.basename(path, ".beam"), bytes} | acc]}}
            {:error, reason} -> {:halt, {:error, "cannot read #{path}: #{inspect(reason)}"}}
          end
        end)
        |> case do
          {:ok, beams} -> {:ok, Enum.reverse(beams)}
          error -> error
        end
    end
  end

  defp unsupported_project_input?(ebin, elixir_beams) do
    root = File.cwd!()
    priv = Path.join(root, "priv")

    File.dir?(Path.join(root, "c_src")) or File.dir?(Path.join(root, "native")) or
      (File.dir?(priv) and File.ls!(priv) != []) or
      Path.wildcard(Path.join(root, "lib/**/*.{erl,exs}")) != [] or
      Path.wildcard(Path.join(root, "src/**/*.erl")) != [] or
      Path.wildcard(Path.join(ebin, "*.beam")) != elixir_beams
  end
end
