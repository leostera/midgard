defmodule Packer.Verifier do
  @moduledoc "Bounded structural verification of an artifact without loading its BEAM modules."

  @max_manifest 262_144
  @max_beam 2_000_000
  @max_modules 512
  @max_total 32_000_000
  @module_pattern ~r/\A(?:Elixir\.[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*|[a-z][A-Za-z0-9_@]*)\z/

  @manifest_keys ~w(application compiler dependencies entrypoint format format_version modules required_capabilities target)
  @module_keys ~w(name owner path sha256 size)

  def verify(dir) when is_binary(dir) do
    with :ok <- regular_directory?(dir),
         {:ok, manifest} <- read_manifest(dir),
         :ok <- validate_manifest(manifest),
         :ok <- validate_files(dir, manifest),
         :ok <- validate_modules(dir, manifest),
         :ok <- validate_ownership(manifest),
         :ok <- validate_entrypoint(dir, manifest),
         :ok <- Packer.Profile.reject_host_imports(dir, manifest) do
      {:ok, manifest}
    end
  end

  def verify(_), do: {:error, "artifact path must be a directory"}

  defp read_manifest(dir) do
    path = Path.join(dir, "manifest.json")

    with :ok <- regular_file?(path),
         {:ok, %{size: size}} <- File.stat(path),
         true <- size in 1..@max_manifest,
         {:ok, bytes} <- File.read(path),
         {:ok, %{} = manifest} <- Packer.JSON.decode(bytes) do
      {:ok, manifest}
    else
      _ -> {:error, "invalid or oversized artifact manifest"}
    end
  end

  defp validate_manifest(m) do
    if valid_manifest_fields?(m) and valid_entrypoint?(m["entrypoint"]) and
         valid_dependencies?(m["dependencies"]) do
      :ok
    else
      {:error, "invalid artifact schema or unsupported capabilities"}
    end
  end

  defp valid_manifest_fields?(m) when is_map(m) do
    modules = m["modules"]

    sorted_keys(m) == @manifest_keys and m["format"] == "midgard.beam" and
      valid_compiler?(m["format_version"], m["compiler"]) and
      identifier?(m["application"]) and is_list(modules) and
      length(modules) in 1..@max_modules and
      Enum.all?(modules, &(is_map(&1) and is_binary(&1["name"]))) and
      is_list(m["dependencies"]) and m["required_capabilities"] == [] and
      m["target"] == %{
        "runtime" => "libbeam",
        "contract" => "provisional-isolate-v1",
        "execution" => "not_verified"
      }
  end

  defp valid_manifest_fields?(_), do: false

  defp valid_entrypoint?(entry) when is_map(entry) do
    sorted_keys(entry) == ~w(arity function module protocol) and
      entry["arity"] == 1 and is_binary(entry["module"]) and
      String.match?(entry["module"], @module_pattern) and
      is_binary(entry["function"]) and
      String.match?(entry["function"], ~r/\A[a-z_][a-z0-9_]*\z/) and
      is_binary(entry["protocol"]) and
      String.match?(entry["protocol"], ~r/\A[a-z][a-z0-9_.-]{0,63}\z/)
  end

  defp valid_entrypoint?(_), do: false

  defp valid_compiler?(1, %{"otp_release" => otp, "elixir_version" => elixir} = fields),
    do:
      sorted_keys(fields) == ~w(elixir_version otp_release) and is_binary(otp) and
        is_binary(elixir)

  defp valid_compiler?(2, %{"otp_release" => otp, "gleam_version" => gleam} = fields),
    do:
      sorted_keys(fields) == ~w(gleam_version otp_release) and is_binary(otp) and
        is_binary(gleam) and byte_size(gleam) in 1..64

  defp valid_compiler?(_, _), do: false

  defp valid_dependencies?(deps) do
    Enum.all?(deps, fn dep ->
      is_map(dep) and sorted_keys(dep) == ~w(app modules version) and
        identifier?(dep["app"]) and is_binary(dep["version"]) and
        is_list(dep["modules"]) and dep["modules"] != [] and
        Enum.all?(dep["modules"], &is_binary/1) and
        dep["modules"] == Enum.sort(Enum.uniq(dep["modules"]))
    end) and
      Enum.map(deps, & &1["app"]) ==
        deps |> Enum.map(& &1["app"]) |> Enum.uniq() |> Enum.sort()
  end

  defp validate_files(dir, %{"modules" => modules}) do
    names = Enum.map(modules, & &1["name"])
    module_dir = Path.join(dir, "modules")
    expected = Enum.map(names, &(&1 <> ".beam")) |> Enum.sort()

    with :ok <- regular_directory?(module_dir),
         {:ok, root_files} <- File.ls(dir),
         true <- Enum.sort(root_files) == ["manifest.json", "modules"],
         {:ok, actual} <- File.ls(module_dir),
         true <- Enum.sort(actual) == expected,
         true <- names == Enum.sort(Enum.uniq(names)) do
      :ok
    else
      _ -> {:error, "artifact files do not match the manifest"}
    end
  end

  defp validate_modules(dir, %{"modules" => modules}) do
    Enum.reduce_while(modules, {:ok, 0}, fn record, {:ok, total} ->
      case validate_module(dir, record) do
        {:ok, size} when total + size <= @max_total -> {:cont, {:ok, total + size}}
        _ -> {:halt, {:error, "invalid, oversized or inconsistent BEAM module"}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp validate_module(dir, record) when is_map(record) do
    name = record["name"]
    owner = record["owner"]
    path = record["path"]
    size = record["size"]
    sha256 = record["sha256"]

    if sorted_keys(record) == @module_keys and is_binary(name) and
         String.match?(name, @module_pattern) and identifier?(owner) and
         path == "modules/#{name}.beam" and is_integer(size) and size in 1..@max_beam and
         is_binary(sha256) and String.match?(sha256, ~r/\A[0-9a-f]{64}\z/) do
      file = Path.join(dir, path)

      with :ok <- regular_file?(file),
           {:ok, %{size: ^size}} <- File.stat(file),
           {:ok, bytes} <- File.read(file),
           ^sha256 <- Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
           {:ok, ^name} <- beam_name(bytes) do
        {:ok, size}
      else
        _ -> {:error, "BEAM file mismatch"}
      end
    else
      {:error, "invalid BEAM manifest record"}
    end
  end

  defp validate_module(_, _), do: {:error, "invalid BEAM record"}

  defp validate_ownership(%{"application" => app, "modules" => modules, "dependencies" => deps}) do
    recorded = Map.new(modules, &{&1["name"], &1["owner"]})

    listed =
      for dep <- deps, module <- dep["modules"], do: {module, dep["app"]}

    if Enum.all?(listed, fn {module, owner} -> recorded[module] == owner end) and
         length(Enum.uniq(Enum.map(listed, &elem(&1, 0)))) == length(listed) and
         Enum.all?(modules, fn m -> m["owner"] == app or {m["name"], m["owner"]} in listed end) and
         Enum.all?(deps, &(&1["app"] != app)) do
      :ok
    else
      {:error, "dependency ownership does not match BEAM modules"}
    end
  end

  defp validate_entrypoint(dir, %{
         "entrypoint" => %{"module" => name, "function" => function},
         "modules" => modules,
         "application" => app
       }) do
    case Enum.find(modules, &(&1["name"] == name)) do
      %{"owner" => ^app, "path" => path} ->
        bytes = File.read!(Path.join(dir, path))

        case :beam_lib.chunks(bytes, [:exports]) do
          {:ok, {_module, [exports: exports]}} ->
            if Enum.any?(exports, fn {exported, arity} ->
                 arity == 1 and Atom.to_string(exported) == function
               end),
               do: :ok,
               else: {:error, "entrypoint does not export #{function}/1"}

          _ ->
            {:error, "invalid entrypoint BEAM exports"}
        end

      _ ->
        {:error, "entrypoint must belong to the worker project"}
    end
  end

  defp beam_name(bytes) do
    case :beam_lib.info(bytes) do
      info when is_list(info) ->
        case info[:module] do
          module when is_atom(module) -> {:ok, Atom.to_string(module)}
          _ -> {:error, "invalid BEAM module"}
        end

      _ ->
        {:error, "invalid BEAM"}
    end
  rescue
    _ -> {:error, "invalid BEAM"}
  catch
    _, _ -> {:error, "invalid BEAM"}
  end

  defp regular_file?(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} -> :ok
      _ -> {:error, "not a regular file"}
    end
  end

  defp regular_directory?(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> :ok
      _ -> {:error, "not a directory"}
    end
  end

  defp identifier?(name), do: is_binary(name) and String.match?(name, ~r/\A[a-z][a-z0-9_]*\z/)
  defp sorted_keys(map), do: map |> Map.keys() |> Enum.sort()
end
