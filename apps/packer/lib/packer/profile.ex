defmodule Packer.Profile do
  @moduledoc """
  Static BEAM import/opcode diagnostics. These are conservative checks, not a
  libbeam loader or proof of bytecode compatibility or NIF-freedom.
  """

  @host_modules ~w(file os prim_file gen_tcp gen_udp inet ssl httpc rpc net_kernel code erl_eval erl_scan erl_parse)a ++
                  [File, System, Port, IO, Node, Mix, RPC]
  @unavailable_modules ~w(ets persistent_term application)a ++ [Code]
  @unavailable_ops ~w(get_map_elements put_map_assoc put_map_exact has_map_fields is_map new_map make_fun3 make_fun2 call_fun call_fun2 is_pid is_port is_reference)a

  def reject_host_imports(dir, manifest) do
    Enum.reduce_while(manifest["modules"], :ok, fn module, :ok ->
      path = Path.join(dir, module["path"])

      with {:ok, entries} <- imports(path),
           :ok <- reject_on_load(path) do
        case Enum.find(entries, &host_import?/1) do
          nil ->
            {:cont, :ok}

          {from, function, arity} ->
            {:halt,
             {:error, "host-authority import #{from}:#{function}/#{arity} in #{module["name"]}"}}
        end
      else
        error -> {:halt, error}
      end
    end)
  end

  def report(dir) do
    with {:ok, manifest} <- Packer.Verifier.verify(dir),
         {:ok, evidence} <- gather(dir, manifest) do
      {:ok,
       %{
         "execution" => "not_verified",
         "contract" => "provisional-isolate-v1",
         "known_unsupported_current_core" => evidence.unsupported |> Enum.uniq() |> Enum.sort(),
         "unresolved_imports" => evidence.unresolved |> Enum.uniq() |> Enum.sort()
       }}
    end
  end

  def summary(report) do
    "Static current-core profile: #{length(report["known_unsupported_current_core"])} known unsupported, " <>
      "#{length(report["unresolved_imports"])} unresolved imports; execution NOT VERIFIED"
  end

  def current_core_check(dir) do
    with {:ok, report} <- report(dir) do
      if report["known_unsupported_current_core"] == [] and report["unresolved_imports"] == [] do
        {:ok, "no known static blockers; libbeam execution still NOT VERIFIED"}
      else
        blockers = report["known_unsupported_current_core"]
        unresolved = report["unresolved_imports"]
        sample = (blockers ++ unresolved) |> Enum.take(3) |> Enum.join("; ")

        {:error,
         "current libbeam core does not admit this artifact: #{length(blockers)} known unsupported, " <>
           "#{length(unresolved)} unresolved imports (e.g. #{sample}); run without --target for details"}
      end
    end
  end

  defp gather(dir, manifest) do
    included = MapSet.new(manifest["modules"], & &1["name"])

    Enum.reduce_while(manifest["modules"], {:ok, %{unsupported: [], unresolved: []}}, fn module,
                                                                                         {:ok,
                                                                                          acc} ->
      path = Path.join(dir, module["path"])

      with {:ok, entries} <- imports(path),
           {:ok, instructions} <- opcodes(path) do
        unsupported =
          for op <- instructions, op in @unavailable_ops, do: "#{module["name"]}: opcode #{op}"

        unsupported =
          unsupported ++
            for {from, function, arity} <- entries,
                from in @unavailable_modules,
                do: "#{module["name"]}: #{from}:#{function}/#{arity}"

        unresolved =
          for {from, function, arity} <- entries,
              not MapSet.member?(included, Atom.to_string(from)) and
                not (from == :erlang and function == :get_module_info and arity in [1, 2]) and
                from not in @unavailable_modules,
              do: "#{module["name"]}: #{from}:#{function}/#{arity}"

        {:cont,
         {:ok,
          %{unsupported: unsupported ++ acc.unsupported, unresolved: unresolved ++ acc.unresolved}}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp imports(path) do
    case :beam_lib.chunks(String.to_charlist(path), [:imports]) do
      {:ok, {_module, [imports: entries]}} -> {:ok, entries}
      _ -> {:error, "could not inspect BEAM imports: #{path}"}
    end
  rescue
    _ -> {:error, "could not inspect BEAM imports: #{path}"}
  catch
    _, _ -> {:error, "could not inspect BEAM imports: #{path}"}
  end

  defp opcodes(path) do
    case :beam_disasm.file(String.to_charlist(path)) do
      {:beam_file, _module, _exports, _attrs, _compile, functions} ->
        {:ok,
         for(
           {:function, _, _, _, code} <- functions,
           instruction <- code,
           do: opcode(instruction)
         )}

      _ ->
        {:error, "could not inspect BEAM opcodes: #{path}"}
    end
  rescue
    _ -> {:error, "could not inspect BEAM opcodes: #{path}"}
  catch
    _, _ -> {:error, "could not inspect BEAM opcodes: #{path}"}
  end

  defp opcode(instruction) when is_tuple(instruction), do: elem(instruction, 0)
  defp opcode(instruction), do: instruction

  defp reject_on_load(path) do
    with {:ok, {_module, [attributes: attrs]}} <-
           :beam_lib.chunks(String.to_charlist(path), [:attributes]),
         {:ok, instructions} <- opcodes(path) do
      if Keyword.has_key?(attrs, :on_load) or :on_load in instructions,
        do: {:error, "on_load module initialization is not supported: #{path}"},
        else: :ok
    else
      _ -> {:error, "could not inspect BEAM initialization: #{path}"}
    end
  end

  defp host_import?({from, function, arity}),
    do:
      from in @host_modules or
        (from == Code and function not in [:ensure_compiled, :ensure_compiled?]) or
        (from == :erlang and function in [:load_nif, :open_port, :halt] and arity in 0..2)
end
