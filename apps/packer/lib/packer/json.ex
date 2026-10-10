defmodule Packer.JSON do
  @moduledoc "Canonical, UTF-8 JSON for the bounded artifact manifest."

  def encode(value), do: value |> encode_value() |> IO.iodata_to_binary()

  def decode(bytes) when is_binary(bytes) do
    try do
      {:ok, :json.decode(bytes)}
    rescue
      _ -> {:error, :invalid_json}
    catch
      _, _ -> {:error, :invalid_json}
    end
  end

  defp encode_value(map) when is_map(map) do
    entries =
      map
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.map(fn {key, value} -> [:json.encode(key), ?:, encode_value(value)] end)

    [?{, Enum.intersperse(entries, ?,), ?}]
  end

  defp encode_value(list) when is_list(list),
    do: [?[, Enum.intersperse(Enum.map(list, &encode_value/1), ?,), ?]]

  defp encode_value(nil), do: "null"

  defp encode_value(value) when is_binary(value) or is_integer(value) or is_boolean(value),
    do: :json.encode(value)
end
