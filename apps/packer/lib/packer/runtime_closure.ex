defmodule Packer.RuntimeClosure do
  @moduledoc """
  Resolves the original BEAM import and external-fun closure on the developer's
  machine. This does not load, rewrite, or execute any code in the serving VM.

  Consolidated Elixir protocols name their implementations only as atoms in
  `impl_for/1`, never as imports, so the walk also follows the implementation
  modules a protocol's atom table names (`Elixir.<Protocol>.<Type>`).
  """

  @max_modules 512

  def collect(application, local, dependencies) do
    roots =
      Enum.reduce(local, %{}, fn {name, bytes}, acc ->
        Map.put(acc, String.to_existing_atom(name), {bytes, application, nil})
      end)

    roots =
      Enum.reduce(dependencies, roots, fn dep, acc ->
        Enum.reduce(dep.beams, acc, fn {name, bytes}, acc ->
          Map.put(acc, String.to_existing_atom(name), {bytes, dep.app, dep.version})
        end)
      end)

    with {:ok, found} <- walk(Map.keys(roots), roots, %{}),
         {:ok, records} <- dependency_records(found, application) do
      modules =
        Enum.map(found, fn {module, {bytes, owner, _version}} ->
          %{name: Atom.to_string(module), owner: owner, bytes: bytes}
        end)

      {:ok, modules, records}
    end
  end

  defp walk([], _roots, found), do: {:ok, found}
  defp walk([:erlang | pending], roots, found), do: walk(pending, roots, found)

  defp walk([module | pending], roots, found) when is_atom(module) do
    cond do
      Map.has_key?(found, module) ->
        walk(pending, roots, found)

      map_size(found) >= @max_modules ->
        {:error, "BEAM dependency closure exceeds 512 modules"}

      true ->
        with {:ok, {beam, owner, version}} <- provider(module, roots),
             {:ok, imports} <- imports(module, beam) do
          walk(imports ++ pending, roots, Map.put(found, module, {beam, owner, version}))
        end
    end
  end

  defp provider(module, roots) do
    case Map.fetch(roots, module) do
      {:ok, record} ->
        {:ok, record}

      :error ->
        path =
          case :code.where_is_file(Atom.to_charlist(module) ++ ~c".beam") do
            candidate when is_list(candidate) ->
              candidate

            _ ->
              # OTP applications such as syntax_tools need not be started by
              # Mix. Find their installed BEAM without loading any module.
              otp = List.to_string(:code.lib_dir())

              case Path.wildcard(Path.join([otp, "*", "ebin", "#{module}.beam"])) do
                [file] -> String.to_charlist(file)
                _ -> :missing
              end
          end

        case path do
          path when is_list(path) ->
            path = List.to_string(path)
            package = path |> Path.dirname() |> Path.dirname() |> Path.basename()
            [owner | _] = String.split(package, "-", parts: 2)

            case File.read(path) do
              {:ok, beam} -> {:ok, {beam, owner, package}}
              _ -> {:error, "cannot read dependency BEAM #{inspect(module)}"}
            end

          _ ->
            {:error, "missing BEAM dependency #{inspect(module)}"}
        end
    end
  end

  defp imports(module, beam) do
    with {:ok, {^module, [imports: imports]}} <- :beam_lib.chunks(beam, [:imports]),
         {:beam_file, ^module, _, _, _, functions} <- :beam_disasm.file(beam) do
      {:ok,
       Enum.map(imports, &elem(&1, 0)) ++
         external_modules(functions) ++ protocol_implementations(module, beam)}
    else
      _ -> {:error, "cannot inspect dependency BEAM #{inspect(module)}"}
    end
  end

  @doc false
  # Implementation modules named by a consolidated protocol, without loading it.
  # Atoms that merely share the prefix (such as Inspect.Opts) are harmless: they
  # are modules too, and a missing BEAM for one is skipped, not an error.
  def protocol_implementations(module, beam) do
    with {:ok, {^module, [exports: exports]}} <- :beam_lib.chunks(beam, [:exports]),
         true <- {:__protocol__, 1} in exports,
         {:ok, {^module, [atoms: atoms]}} <- :beam_lib.chunks(beam, [:atoms]) do
      prefix = Atom.to_string(module) <> "."

      for {_index, atom} <- atoms,
          String.starts_with?(Atom.to_string(atom), prefix),
          available?(atom),
          do: atom
    else
      _ -> []
    end
  end

  defp available?(module) do
    is_list(:code.where_is_file(Atom.to_charlist(module) ++ ~c".beam"))
  end

  defp external_modules(term) when is_function(term) do
    case :erlang.fun_info(term, :type) do
      {:type, :external} -> [elem(:erlang.fun_info_mfa(term), 0)]
      _ -> []
    end
  end

  defp external_modules(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> external_modules()

  defp external_modules([head | tail]), do: external_modules(head) ++ external_modules(tail)
  defp external_modules(term) when is_map(term), do: term |> Map.to_list() |> external_modules()
  defp external_modules(_), do: []

  defp dependency_records(found, application) do
    groups =
      found
      |> Enum.reject(fn {_module, {_bytes, owner, _version}} -> owner == application end)
      |> Enum.group_by(fn {_module, {_bytes, owner, version}} -> {owner, version} end, fn {module,
                                                                                           _} ->
        Atom.to_string(module)
      end)

    records =
      Enum.map(groups, fn {{owner, version}, names} ->
        %{app: owner, version: version || "local", modules: names}
      end)

    if length(Enum.uniq_by(records, & &1.app)) == length(records) do
      {:ok, records}
    else
      {:error, "BEAM dependencies contain ambiguous application versions"}
    end
  end
end
