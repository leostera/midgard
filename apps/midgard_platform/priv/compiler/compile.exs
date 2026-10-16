# Runs only in the restricted compiler container. Never eval this on the host.
[application, entrypoint, image_digest] = System.argv()

unless Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, application) and
         Regex.match?(~r/\AElixir\.[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*\z/, entrypoint) do
  raise "invalid compiler arguments"
end

sdk_files = ~w(request.ex protocol.ex worker.ex)
sdk_hash =
  sdk_files
  |> Enum.map(&File.read!("/workspace/sdk/#{&1}"))
  |> then(&:crypto.hash(:sha256, &1))
  |> Base.encode16(case: :lower)

sdk =
  for file <- sdk_files, reduce: %{} do
    acc ->
      modules = Code.compile_file("/workspace/sdk/#{file}")
      Map.merge(acc, Map.new(modules))
  end

user = Map.new(Code.compile_file("/workspace/worker.ex"))

unless Map.has_key?(user, String.to_existing_atom(entrypoint)) and
         Enum.all?(user, fn {module, _} ->
           name = Atom.to_string(module)
           name == entrypoint or String.starts_with?(name, entrypoint <> ".")
         end) do
  raise "source must define #{entrypoint} and may only define nested modules"
end

roots = Map.merge(sdk, user)

external_modules = fn recurse ->
  fn
    term when is_function(term) ->
      case :erlang.fun_info(term, :type) do
        {:type, :external} -> [elem(:erlang.fun_info_mfa(term), 0)]
        _ -> []
      end

    term when is_tuple(term) -> recurse.(recurse).(Tuple.to_list(term))
    [head | tail] -> recurse.(recurse).(head) ++ recurse.(recurse).(tail)
    term when is_map(term) -> recurse.(recurse).(Map.to_list(term))
    _ -> []
  end
end

walk = fn recurse, pending, found ->
  case pending do
    [] -> found
    [:erlang | rest] -> recurse.(recurse, rest, found)
    [module | rest] ->
      if Map.has_key?(found, module) do
        recurse.(recurse, rest, found)
      else
        {beam, owner, version} =
          case Map.fetch(roots, module) do
            {:ok, beam} ->
              if Map.has_key?(user, module),
                do: {beam, application, nil},
                else: {beam, "midgard", "0.1.0-dev+sdk.#{sdk_hash}@#{image_digest}"}

            :error ->
              path = :code.where_is_file(Atom.to_charlist(module) ++ ~c".beam")

              unless is_list(path), do: raise("missing BEAM provider #{inspect(module)}")
              path = List.to_string(path)
              package = path |> Path.dirname() |> Path.dirname() |> Path.basename()
              [owner | _] = String.split(package, "-", parts: 2)
              {File.read!(path), owner, "#{package}@#{image_digest}"}
          end

        {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(beam, [:imports])
        {:beam_file, ^module, _, _, _, functions} = :beam_disasm.file(beam)
        dependencies = Enum.map(imports, &elem(&1, 0)) ++ external_modules.(external_modules).(functions)
        recurse.(recurse, dependencies ++ rest, Map.put(found, module, {beam, owner, version}))
      end
  end
end

closure = walk.(walk, Map.keys(roots), %{})
unless map_size(closure) in 1..512, do: raise("module closure exceeds shipment limit")

records =
  closure
  |> Enum.sort_by(fn {name, _} -> Atom.to_string(name) end)
  |> Enum.map(fn {module, {bytes, owner, _version}} ->
    name = Atom.to_string(module)
    path = "modules/#{name}.beam"
    File.write!("/output/#{path}", bytes)

    %{
      "name" => name,
      "owner" => owner,
      "path" => path,
      "size" => byte_size(bytes),
      "sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    }
  end)

unless Enum.reduce(records, 0, fn item, total -> total + item["size"] end) <= 32_000_000,
  do: raise("module closure exceeds 32 MB")

dependencies =
  closure
  |> Enum.reject(fn {name, _} -> Map.has_key?(user, name) end)
  |> Enum.group_by(fn {_name, {_bytes, owner, version}} -> {owner, version} end, fn {name, _} ->
    Atom.to_string(name)
  end)
  |> Enum.map(fn {{owner, version}, modules} ->
    %{"app" => owner, "version" => version, "modules" => Enum.sort(modules)}
  end)
  |> Enum.sort_by(& &1["app"])

if length(dependencies) != length(Enum.uniq_by(dependencies, & &1["app"])),
  do: raise("ambiguous dependency versions in compiler image")

manifest = %{
  "format" => "midgard.beam",
  "format_version" => 1,
  "application" => application,
  "entrypoint" => %{
    "module" => entrypoint,
    "function" => "__midgard_call__",
    "arity" => 1,
    "protocol" => "midgard.bytes.v1"
  },
  "compiler" => %{
    "otp_release" => to_string(:erlang.system_info(:otp_release)),
    "elixir_version" => System.version()
  },
  "target" => %{
    "runtime" => "libbeam",
    "contract" => "provisional-isolate-v1",
    "execution" => "not_verified"
  },
  "dependencies" => dependencies,
  "modules" => records,
  "required_capabilities" => []
}

File.write!("/output/manifest.json", [:json.encode(manifest), "\n"])
IO.puts("Compiled #{map_size(user)} user modules; resolved #{map_size(closure)} original BEAMs")
