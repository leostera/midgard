defmodule TodoWeb.Router do
  @moduledoc """
  Loopback-only demonstration adapter. It passes bounded binary frames to a
  worker running on ordinary OTP, never to libbeam or a general deploy host.
  """

  @behaviour Plug
  import Plug.Conn

  alias Midgard.{Protocol, Request}

  @max_body 32_768
  @allowed_hosts ["127.0.0.1", "localhost"]

  @impl true
  def init(options), do: options

  @impl true
  def call(conn, options) do
    if conn.host in @allowed_hosts do
      route(conn, options)
    else
      json_error(conn, 403, "Local host required.")
    end
  end

  defp route(%Plug.Conn{method: "GET", request_path: "/"} = conn, options) do
    html = TodoWeb.Page.render(options[:csrf_token], :todo_store.list())

    conn
    |> put_resp_header("content-type", "text/html; charset=utf-8")
    |> put_resp_header(
      "content-security-policy",
      "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'"
    )
    |> send(200, html)
  end

  defp route(%Plug.Conn{method: "GET", request_path: path} = conn, _options)
       when path in ["/app.css", "/app.js"] do
    file = if path == "/app.css", do: "app.css", else: "app.js"
    content_type = if path == "/app.css", do: "text/css", else: "text/javascript"

    conn
    |> put_resp_header("content-type", content_type <> "; charset=utf-8")
    |> send(200, File.read!(Application.app_dir(:todo_web, "priv/#{file}")))
  end

  defp route(%Plug.Conn{method: "GET", request_path: "/favicon.svg"} = conn, _options) do
    conn
    |> put_resp_header("content-type", "image/svg+xml")
    |> send(200, File.read!(Application.app_dir(:todo_web, "priv/favicon.svg")))
  end

  defp route(%Plug.Conn{method: "GET", request_path: "/favicon.ico"} = conn, _options),
    do: send(conn, 204, "")

  defp route(%Plug.Conn{method: "GET", request_path: "/fonts/" <> name} = conn, _options)
       when name in ["BarlowCondensed-SemiBold.ttf", "BarlowCondensed-Bold.ttf"] do
    conn
    |> put_resp_header("content-type", "font/ttf")
    |> send(200, File.read!(Application.app_dir(:todo_web, "priv/fonts/#{name}")))
  end

  defp route(%Plug.Conn{request_path: "/api/todos"} = conn, options),
    do: dispatch_api(conn, options)

  defp route(%Plug.Conn{request_path: "/api/todos/" <> _} = conn, options),
    do: dispatch_api(conn, options)

  defp route(conn, _options), do: json_error(conn, 404, "Route not found.")

  defp dispatch_api(%Plug.Conn{method: method} = conn, options)
       when method in ["POST", "PATCH", "DELETE"] do
    if valid_mutation?(conn, options[:csrf_token]) do
      forward(conn)
    else
      json_error(conn, 403, "Invalid local request token or origin.")
    end
  end

  defp dispatch_api(conn, _options), do: forward(conn)

  defp forward(conn) do
    with {:ok, conn, body} <- bounded_body(conn),
         request = %Request{
           method: conn.method,
           path: conn.request_path,
           query_string: conn.query_string,
           headers:
             Enum.filter(conn.req_headers, fn {name, _value} ->
               name in ["accept", "content-type"]
             end),
           body: body
         },
         {:ok, frame} <- Protocol.request(request),
         {:ok, {status, response}} <-
           frame |> TodoWorker.__midgard_call__() |> Protocol.decode_response() do
      if status == 500 do
        json_error(conn, 500, "Local worker failed.")
      else
        conn
        |> put_resp_header("content-type", "application/json; charset=utf-8")
        |> send(status, response)
      end
    else
      {:error, %Plug.Conn{} = conn} -> json_error(conn, 413, "Request body exceeds 32 KiB.")
      _ -> json_error(conn, 400, "Malformed or oversized request.")
    end
  end

  defp bounded_body(conn) do
    case read_body(conn, length: @max_body, read_length: @max_body + 1, read_timeout: 5_000) do
      {:ok, body, conn} -> {:ok, conn, body}
      {:more, _partial, conn} -> {:error, conn}
      {:error, _reason} -> {:error, conn}
    end
  end

  defp valid_mutation?(conn, expected) when is_binary(expected) do
    origin = get_req_header(conn, "origin")
    same_origin = origin == [] or origin == ["http://#{conn.host}:#{conn.port}"]

    token_matches =
      case get_req_header(conn, "x-csrf-token") do
        [given] when byte_size(given) == byte_size(expected) ->
          Plug.Crypto.secure_compare(given, expected)

        _ ->
          false
      end

    same_origin and token_matches
  end

  defp valid_mutation?(_, _), do: false

  defp json_error(conn, status, message),
    do:
      conn
      |> put_resp_header("content-type", "application/json; charset=utf-8")
      |> send(status, Jason.encode!(%{error: message}))

  defp send(conn, status, body) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> send_resp(status, body)
  end
end
