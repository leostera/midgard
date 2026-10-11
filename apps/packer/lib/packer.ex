defmodule Packer do
  @moduledoc """
  Trusted local compiler/assembler for exact-name BEAM artifacts. Mix and
  rebar3 compilation have ordinary developer authority. Neither packaging nor
  inspection loads modules into a serving VM or executes an Isolate.
  """

  @doc "Builds a versioned artifact from the current Mix app, or from `:project` (one rebar3 app)."
  def pack(opts \\ [])

  def pack(opts) when is_list(opts) do
    if Keyword.has_key?(opts, :project),
      do: Packer.Rebar3.pack(opts),
      else: pack_mix(opts)
  end

  def pack(_), do: {:error, "expected keyword pack options"}

  defp pack_mix(opts) do
    app = Keyword.get(opts, :app, Mix.Project.config()[:app])
    entry = Keyword.get(opts, :entry)
    output = Keyword.get(opts, :output, "#{app}.midgard")

    with :ok <- validate_mix_options(app, entry, output),
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

  defp validate_mix_options(app, entry, output) do
    if is_atom(app) and app not in [nil, true, false] and app == Mix.Project.config()[:app] and
         Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, Atom.to_string(app)) and
         (is_atom(entry) or is_binary(entry)) and is_binary(output) and output != "" and
         not String.contains?(output, <<0>>) do
      :ok
    else
      {:error, "expected current Mix :app, :entry module and output directory"}
    end
  end

  defp module_name(entry) when is_atom(entry), do: Atom.to_string(entry)
  defp module_name("Elixir." <> _ = entry), do: entry
  defp module_name(<<first, _::binary>> = entry) when first in ?a..?z, do: entry
  defp module_name(entry), do: "Elixir." <> entry

  defp local_modules(app) do
    root = File.cwd!()
    ebin = Path.join([Mix.Project.build_path(), "lib", Atom.to_string(app), "ebin"])
    Packer.BeamFiles.collect(root, ebin)
  end
end
