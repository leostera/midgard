defmodule Midgard.Protocol do
  @moduledoc """
  Provisional `midgard.bytes.v1` request/response codec for a future binary
  arity-one libbeam Isolate invocation. No Erlang term decoding or host handles.
  """

  alias Midgard.Request

  @max_bytes 65_536
  @max_path 2_048
  @max_query 2_048
  @max_body 32_768
  @max_headers 32
  @max_header_bytes 8_192

  def request(%Request{} = request) do
    %{method: method, path: path, query_string: query, headers: headers, body: body} = request

    with true <- valid_fields?(method, path, query, body, headers),
         {:ok, header_bytes} <- encode_headers(headers) do
      bytes =
        <<1, byte_size(method)::8, byte_size(path)::16, byte_size(query)::16, length(headers)::8,
          byte_size(body)::16, method::binary, path::binary, query::binary, header_bytes::binary,
          body::binary>>

      if byte_size(bytes) <= @max_bytes, do: {:ok, bytes}, else: {:error, :invalid_request}
    else
      _ -> {:error, :invalid_request}
    end
  end

  def request(_), do: {:error, :invalid_request}

  def decode_request(
        <<1, method_size::8, path_size::16, query_size::16, count::8, body_size::16,
          rest::binary>> = bytes
      )
      when byte_size(bytes) <= @max_bytes and method_size in 1..16 and
             path_size in 1..@max_path and query_size <= @max_query and count <= @max_headers and
             body_size <= @max_body do
    with <<method::binary-size(^method_size), path::binary-size(^path_size),
           query::binary-size(^query_size), tail::binary>> <- rest,
         {:ok, headers, <<body::binary-size(^body_size)>>} <- parse_headers(tail, count, [], 0),
         request = %Request{
           method: method,
           path: path,
           query_string: query,
           headers: headers,
           body: body
         },
         {:ok, _} <- request(request) do
      {:ok, request}
    else
      _ -> {:error, :invalid_request}
    end
  end

  def decode_request(_), do: {:error, :invalid_request}

  def response({status, body})
      when is_integer(status) and status in 100..599 and is_binary(body) and
             byte_size(body) <= @max_bytes - 5 do
    {:ok, <<2, status::16, byte_size(body)::16, body::binary>>}
  end

  def response(_), do: {:error, :invalid_response}

  def decode_response(<<2, status::16, size::16, body::binary-size(size)>>)
      when status in 100..599,
      do: {:ok, {status, body}}

  def decode_response(_), do: {:error, :invalid_response}

  defp valid_fields?(method, path, query, body, headers) do
    is_binary(method) and byte_size(method) in 1..16 and
      String.match?(method, ~r/\A[A-Z]+\z/) and is_binary(path) and
      byte_size(path) in 1..@max_path and match?(<<"/", _::binary>>, path) and
      is_binary(query) and byte_size(query) <= @max_query and is_binary(body) and
      byte_size(body) <= @max_body and is_list(headers) and length(headers) <= @max_headers
  end

  defp encode_headers(headers) do
    Enum.reduce_while(headers, {:ok, [], 0}, fn
      {name, value}, {:ok, acc, total} when is_binary(name) and is_binary(value) ->
        size = byte_size(name) + byte_size(value) + 3

        if byte_size(name) in 1..128 and byte_size(value) <= 4_096 and
             total + size <= @max_header_bytes and
             String.match?(name, ~r/\A[a-z0-9-]+\z/) and
             :binary.match(value, ["\r", "\n"]) == :nomatch do
          {:cont,
           {:ok,
            [<<byte_size(name)::8, byte_size(value)::16, name::binary, value::binary>> | acc],
            total + size}}
        else
          {:halt, {:error, :invalid_request}}
        end

      _, _ ->
        {:halt, {:error, :invalid_request}}
    end)
    |> case do
      {:ok, acc, _} -> {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
      error -> error
    end
  end

  defp parse_headers(rest, 0, acc, total) when total <= @max_header_bytes,
    do: {:ok, Enum.reverse(acc), rest}

  defp parse_headers(
         <<name_size::8, value_size::16, name::binary-size(name_size),
           value::binary-size(value_size), rest::binary>>,
         count,
         acc,
         total
       )
       when count > 0 and total + name_size + value_size + 3 <= @max_header_bytes,
       do:
         parse_headers(rest, count - 1, [{name, value} | acc], total + name_size + value_size + 3)

  defp parse_headers(_, _, _, _), do: {:error, :invalid_request}
end
