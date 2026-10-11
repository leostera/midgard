defmodule TodoWorker do
  @moduledoc """
  Provisional Midgard HTTP worker on ordinary OTP. An Erlang gen_server owns
  the in-memory list; this module only validates and translates byte requests.
  Neither that process nor this Elixir facade has run inside libbeam.
  """

  use Midgard.Worker
  alias Midgard.Request

  @max_title_bytes 160
  @max_id 1_000_000_000

  @impl true
  def handle_request(%Request{method: "GET", path: "/api/todos"}),
    do: json(200, %{todos: :todo_store.list()})

  def handle_request(%Request{method: "POST", path: "/api/todos", body: bytes}) do
    with {:ok, %{"title" => title} = fields} when map_size(fields) == 1 <- decode_json(bytes),
         {:ok, title} <- clean_title(title) do
      case :todo_store.create(title) do
        {:ok, todo} -> json(201, %{todo: todo})
        {:error, :full} -> json(409, %{error: "List full (60 tasks). Remove one to add another."})
      end
    else
      _ -> json(400, %{error: "Provide a title of 1–160 bytes."})
    end
  end

  def handle_request(%Request{method: method, path: "/api/todos/" <> id_text} = request)
      when method in ["PATCH", "DELETE"] do
    with {:ok, id} <- parse_id(id_text) do
      change(method, id, request.body)
    else
      _ -> json(400, %{error: "Invalid to-do ID."})
    end
  end

  def handle_request(_), do: json(404, %{error: "Route not found."})

  defp change("PATCH", id, bytes) do
    with {:ok, fields} <- decode_json(bytes),
         {:ok, changes} <- validate_changes(fields) do
      case :todo_store.update(id, changes) do
        {:ok, todo} -> json(200, %{todo: todo})
        {:error, :not_found} -> json(404, %{error: "To-do not found."})
      end
    else
      _ -> json(400, %{error: "Provide a valid title and/or completed value."})
    end
  end

  defp change("DELETE", id, _bytes) do
    case :todo_store.delete(id) do
      :ok -> {204, ""}
      {:error, :not_found} -> json(404, %{error: "To-do not found."})
    end
  end

  defp decode_json(bytes) when is_binary(bytes) do
    case Jason.decode(bytes) do
      {:ok, %{} = fields} -> {:ok, fields}
      _ -> {:error, :invalid_json}
    end
  rescue
    _ -> {:error, :invalid_json}
  end

  defp parse_id(text) when byte_size(text) in 1..10 do
    case Integer.parse(text) do
      {id, ""} when id in 1..@max_id -> {:ok, id}
      _ -> {:error, :invalid_id}
    end
  end

  defp parse_id(_), do: {:error, :invalid_id}

  defp validate_changes(fields) when is_map(fields) and map_size(fields) in 1..2 do
    Enum.reduce_while(fields, {:ok, %{}}, fn
      {"title", title}, {:ok, changes} ->
        case clean_title(title) do
          {:ok, value} -> {:cont, {:ok, Map.put(changes, :title, value)}}
          error -> {:halt, error}
        end

      {"completed", completed}, {:ok, changes} when is_boolean(completed) ->
        {:cont, {:ok, Map.put(changes, :completed, completed)}}

      _, _ ->
        {:halt, {:error, :invalid_changes}}
    end)
  end

  defp validate_changes(_), do: {:error, :invalid_changes}

  defp clean_title(title) when is_binary(title) do
    if String.valid?(title) do
      trimmed = String.trim(title)

      if byte_size(trimmed) in 1..@max_title_bytes and
           not String.contains?(trimmed, ["\r", "\n", <<0>>]) do
        {:ok, trimmed}
      else
        {:error, :invalid_title}
      end
    else
      {:error, :invalid_title}
    end
  end

  defp clean_title(_), do: {:error, :invalid_title}

  defp json(status, data), do: {status, Jason.encode!(data)}
end
