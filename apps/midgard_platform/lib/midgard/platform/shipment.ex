defmodule Midgard.Platform.Shipment do
  @moduledoc """
  Reads a bounded, local `.midgard/` directory into an immutable BEAM group.

  Hashes and exact filenames are checked before crossing the native Port.
  The libbeam loader independently verifies the BEAMs and *all* imports on
  atomic group admission. This local reader is not an adversarial upload API:
  callers must stage immutable files and enforce authorization beforehand.
  """
  @enforce_keys [:application, :module, :function, :protocol, :language, :modules, :digest]
  defstruct [:application, :module, :function, :protocol, :language, :modules, :digest]

  @max_manifest 262_144
  @max_modules 512
  @max_beam 2_000_000
  @max_total 32_000_000
  @module_name ~r/\A(?:Elixir\.[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*|[a-z][A-Za-z0-9_@]*)\z/
  @function_name ~r/\A[a-z_][a-z0-9_]*\z/
  @hash ~r/\A[0-9a-f]{64}\z/

  def read(path) when is_binary(path) do
    with :ok <- regular_dir(path),
         :ok <- exact_files(path, ["manifest.json", "modules"]),
         {:ok, bytes} <- bounded_file(Path.join(path, "manifest.json"), @max_manifest),
         {:ok, manifest} <- decode(bytes),
         :ok <- validate_manifest(manifest),
         {:ok, protocol} <- parse_protocol(manifest["entrypoint"]["protocol"]),
         {:ok, language} <- parse_language(manifest),
         {:ok, modules} <- read_modules(path, manifest["modules"]) do
      entry = manifest["entrypoint"]

      {:ok,
       %__MODULE__{
         application: manifest["application"],
         module: entry["module"],
         function: entry["function"],
         protocol: protocol,
         language: language,
         modules: modules,
         digest: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
       }}
    end
  end

  def read(_), do: {:error, "shipment path must be a directory"}

  defp decode(bytes) do
    case :json.decode(bytes) do
      %{} = manifest -> {:ok, manifest}
      _ -> {:error, "manifest must be an object"}
    end
  rescue
    _ -> {:error, "invalid manifest JSON"}
  catch
    _, _ -> {:error, "invalid manifest JSON"}
  end

  defp validate_manifest(manifest) do
    entry = manifest["entrypoint"]
    modules = manifest["modules"]
    application = manifest["application"]

    if Enum.sort(Map.keys(manifest)) ==
         ~w(application compiler dependencies entrypoint format format_version modules required_capabilities target) and
         manifest["format"] == "midgard.beam" and manifest["format_version"] in [1, 2] and
         manifest["required_capabilities"] == [] and
         manifest["target"] == %{
           "runtime" => "libbeam",
           "contract" => "provisional-isolate-v1",
           "execution" => "not_verified"
         } and is_binary(application) and String.match?(application, ~r/\A[a-z][a-z0-9_]*\z/) and
         is_map(entry) and Enum.sort(Map.keys(entry)) == ~w(arity function module protocol) and
         entry["arity"] == 1 and is_binary(entry["module"]) and
         String.match?(entry["module"], @module_name) and
         is_binary(entry["function"]) and String.match?(entry["function"], @function_name) and
         is_list(modules) and length(modules) in 1..@max_modules and
         Enum.all?(modules, &valid_record?/1) and
         Enum.map(modules, & &1["name"]) ==
           modules |> Enum.map(& &1["name"]) |> Enum.uniq() |> Enum.sort() and
         Enum.any?(modules, &(&1["name"] == entry["module"] and &1["owner"] == application)) do
      :ok
    else
      {:error, "invalid or unsupported shipment manifest"}
    end
  end

  defp parse_protocol("midgard.bytes.v1"), do: {:ok, :midgard}
  defp parse_protocol("raw.bytes.v1"), do: {:ok, :raw}
  defp parse_protocol(_), do: {:error, "unsupported worker byte protocol"}

  defp parse_language(%{"format_version" => 2, "compiler" => compiler})
       when is_map(compiler) do
    case compiler do
      %{"gleam_version" => version, "otp_release" => otp}
      when is_binary(version) and is_binary(otp) ->
        if Enum.sort(Map.keys(compiler)) == ~w(gleam_version otp_release),
          do: {:ok, :gleam},
          else: {:error, "unsupported compiler metadata"}

      _ ->
        {:error, "unsupported compiler metadata"}
    end
  end

  defp parse_language(%{"format_version" => 1, "compiler" => compiler, "entrypoint" => entry})
       when is_map(compiler) do
    if Enum.sort(Map.keys(compiler)) == ~w(elixir_version otp_release) and
         is_binary(compiler["elixir_version"]) and is_binary(compiler["otp_release"]) do
      case entry["module"] do
        "Elixir." <> _ -> {:ok, :elixir}
        _ -> {:ok, :erlang}
      end
    else
      {:error, "unsupported compiler metadata"}
    end
  end

  defp parse_language(_), do: {:error, "unsupported compiler metadata"}

  defp valid_record?(%{} = record) do
    Enum.sort(Map.keys(record)) == ~w(name owner path sha256 size) and
      is_binary(record["name"]) and String.match?(record["name"], @module_name) and
      is_binary(record["owner"]) and
      String.match?(record["owner"], ~r/\A[a-z][a-z0-9_]*\z/) and
      record["path"] == "modules/#{record["name"]}.beam" and
      is_integer(record["size"]) and record["size"] in 1..@max_beam and
      is_binary(record["sha256"]) and String.match?(record["sha256"], @hash)
  end

  defp valid_record?(_), do: false

  defp read_modules(root, records) do
    dir = Path.join(root, "modules")
    expected = Enum.map(records, &(&1["name"] <> ".beam"))

    with :ok <- regular_dir(dir),
         :ok <- exact_files(dir, expected) do
      Enum.reduce_while(records, {:ok, [], 0}, fn record, {:ok, acc, total} ->
        with true <- total + record["size"] <= @max_total,
             {:ok, beam} <- bounded_file(Path.join(dir, record["name"] <> ".beam"), @max_beam),
             true <- byte_size(beam) == record["size"],
             digest <- Base.encode16(:crypto.hash(:sha256, beam), case: :lower),
             true <- digest == record["sha256"] do
          {:cont, {:ok, [beam | acc], total + byte_size(beam)}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
          _ -> {:halt, {:error, "shipment BEAM size or checksum mismatch: #{record["name"]}"}}
        end
      end)
      |> case do
        {:ok, reversed, _total} -> {:ok, Enum.reverse(reversed)}
        error -> error
      end
    end
  end

  defp regular_dir(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> :ok
      _ -> {:error, "shipment directory is missing or is a symlink"}
    end
  end

  defp exact_files(path, expected) do
    case File.ls(path) do
      {:ok, names} ->
        if Enum.sort(names) == Enum.sort(expected),
          do: :ok,
          else: {:error, "shipment contains missing or undeclared files"}

      _ ->
        {:error, "cannot list shipment directory"}
    end
  end

  defp bounded_file(path, maximum) do
    with {:ok, %{type: :regular, size: size}} when size >= 1 and size <= maximum <-
           File.lstat(path),
         {:ok, bytes} <- File.read(path),
         true <- byte_size(bytes) == size do
      {:ok, bytes}
    else
      _ -> {:error, "shipment file is missing, oversized, or a symlink"}
    end
  end
end
