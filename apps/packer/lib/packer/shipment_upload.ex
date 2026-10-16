defmodule Packer.ShipmentUpload do
  @moduledoc """
  Bounded transport for an already-built `.midgard/` directory. It preserves
  manifest and BEAM bytes; only Shipment.read/1 establishes artifact validity.
  """
  @enforce_keys [:application, :manifest, :modules]
  defstruct [:application, :manifest, :modules]

  @magic "MIDGARD-SHIPMENT-1\n"
  @max_manifest 262_144
  @max_module 2_000_000
  @max_total 32_000_000
  @max_wire 34_000_000
  @module_name ~r/\A(?:Elixir\.[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*|[a-z][A-Za-z0-9_@]*)\z/
  @app_name ~r/\A[a-z][a-z0-9_]{0,39}\z/

  def max_wire, do: @max_wire
  def content_type, do: "application/vnd.midgard.shipment.v1"

  def read_directory(path) when is_binary(path) do
    # The developer's project is trusted locally, but the API will not be.
    with {:ok, manifest} <- File.read(Path.join(path, "manifest.json")),
         true <- byte_size(manifest) in 1..@max_manifest,
         {:ok, %{"application" => app, "modules" => records}} <- decode_manifest(manifest),
         true <- valid_app?(app) and is_list(records) and length(records) in 1..512,
         {:ok, files} <- read_files(path, records) do
      {:ok, %__MODULE__{application: app, manifest: manifest, modules: files}}
    else
      _ -> {:error, "not a bounded .midgard shipment directory"}
    end
  end

  def encode(%__MODULE__{manifest: manifest, modules: modules}) do
    chunks =
      Enum.map(modules, fn {name, bytes} ->
        <<byte_size(name)::16, byte_size(bytes)::32, name::binary, bytes::binary>>
      end)

    [@magic, <<byte_size(manifest)::32, length(modules)::16>>, manifest, chunks]
    |> IO.iodata_to_binary()
  end

  def parse(body) when is_binary(body) and byte_size(body) <= @max_wire do
    case body do
      <<@magic, size::32, count::16, manifest::binary-size(size), rest::binary>>
      when size in 1..@max_manifest and count in 1..512 ->
        with {:ok, %{"application" => app}} <- decode_manifest(manifest),
             true <- valid_app?(app),
             {:ok, modules, <<>>} <- parse_modules(rest, count, [], 0) do
          {:ok, %__MODULE__{application: app, manifest: manifest, modules: modules}}
        else
          _ -> {:error, "invalid shipment upload"}
        end

      _ ->
        {:error, "invalid shipment upload"}
    end
  end

  def parse(_), do: {:error, "invalid shipment upload"}

  def write(%__MODULE__{} = upload, directory) do
    # Only validated names are used for paths; exact files and checksums are
    # verified independently by Shipment.read before native admission.
    with :ok <- File.mkdir(directory),
         :ok <- File.mkdir(Path.join(directory, "modules")),
         :ok <- File.write(Path.join(directory, "manifest.json"), upload.manifest) do
      Enum.reduce_while(upload.modules, :ok, fn {name, bytes}, _ ->
        case File.write(Path.join([directory, "modules", name <> ".beam"]), bytes, [:exclusive]) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp decode_manifest(bytes) do
    case :json.decode(bytes) do
      %{} = manifest -> {:ok, manifest}
      _ -> {:error, :invalid_manifest}
    end
  rescue
    _ -> {:error, :invalid_manifest}
  end

  defp read_files(root, records) do
    Enum.reduce_while(records, {:ok, [], 0}, fn record, {:ok, acc, total} ->
      case record do
        %{"name" => name, "path" => path} when is_binary(name) ->
          if valid_name?(name) and path == "modules/#{name}.beam" and
               not Enum.any?(acc, fn {seen, _} -> seen == name end) do
            file = Path.join([root, "modules", name <> ".beam"])

            case File.lstat(file) do
              {:ok, %{type: :regular, size: size}}
              when size in 1..@max_module and total + size <= @max_total ->
                case File.read(file) do
                  {:ok, bytes} when byte_size(bytes) == size ->
                    {:cont, {:ok, [{name, bytes} | acc], total + size}}

                  _ ->
                    {:halt, {:error, :invalid_module_file}}
                end

              _ ->
                {:halt, {:error, :invalid_module_file}}
            end
          else
            {:halt, {:error, :invalid_module_name}}
          end

        _ ->
          {:halt, {:error, :invalid_module_record}}
      end
    end)
    |> case do
      {:ok, files, _} -> {:ok, Enum.reverse(files)}
      error -> error
    end
  end

  defp parse_modules(rest, 0, acc, _total), do: {:ok, Enum.reverse(acc), rest}

  defp parse_modules(<<name_size::16, beam_size::32, tail::binary>>, count, acc, total)
       when name_size in 1..256 and beam_size in 1..@max_module and
              total + beam_size <= @max_total do
    case tail do
      <<name::binary-size(^name_size), beam::binary-size(^beam_size), rest::binary>> ->
        if valid_name?(name) and not Enum.any?(acc, fn {seen, _} -> seen == name end) do
          parse_modules(rest, count - 1, [{name, beam} | acc], total + beam_size)
        else
          {:error, :duplicate_or_invalid_module}
        end

      _ ->
        {:error, :truncated_module}
    end
  end

  defp parse_modules(_, _, _, _), do: {:error, :invalid_module}
  defp valid_app?(name), do: is_binary(name) and Regex.match?(@app_name, name)

  defp valid_name?(name),
    do: is_binary(name) and byte_size(name) <= 256 and Regex.match?(@module_name, name)
end
