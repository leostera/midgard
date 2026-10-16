defmodule Midgard.Platform.Router do
  @moduledoc "Local-only editor, deployment actions and callable worker URLs."
  use Plug.Router
  alias Midgard.Platform.{Page, Publisher, Workspace}

  plug(:local_request)
  plug(:match)
  plug(:dispatch)

  get "/" do
    html(conn, Page.index(Workspace.list()))
  end

  get "/workers/new" do
    html(conn, Page.new_worker(csrf()))
  end

  post "/workers" do
    with {:ok, fields, conn} <- form(conn),
         :ok <- authorized(fields),
         :ok <- Workspace.create(fields["name"]) do
      redirect(conn, "/workers/#{fields["name"]}")
    else
      {:error, reason, conn} -> html(conn, Page.new_worker(csrf(), reason), 422)
      {:error, reason} -> html(conn, Page.new_worker(csrf(), reason), 422)
    end
  end

  get "/workers/:slug" do
    case Workspace.read(slug) do
      {:ok, %{source: source, record: record}} ->
        html(conn, Page.editor(slug, source, record, csrf(), conn.port))

      _ ->
        html(conn, Page.not_found(), 404)
    end
  end

  post "/workers/:slug/deploy" do
    with {:ok, fields, conn} <- form(conn),
         :ok <- authorized(fields),
         source when is_binary(source) <- fields["source"],
         {:ok, _live} <- Publisher.deploy(slug, source) do
      redirect(conn, "/workers/#{slug}")
    else
      {:error, reason, conn} -> deploy_error(conn, slug, reason)
      {:error, reason} -> deploy_error(conn, slug, reason)
      _ -> deploy_error(conn, slug, "source must be text")
    end
  end

  get "/assets/app.css" do
    path = Application.app_dir(:midgard_platform, "priv/static/app.css")
    conn |> put_resp_content_type("text/css") |> send_resp(200, File.read!(path))
  end

  get "/assets/favicon.svg" do
    path = Application.app_dir(:midgard_platform, "priv/static/favicon.svg")
    conn |> put_resp_content_type("image/svg+xml") |> send_resp(200, File.read!(path))
  end

  get "/assets/fonts/:filename" do
    if filename in ["BarlowCondensed-Bold.ttf", "BarlowCondensed-SemiBold.ttf"] do
      path = Application.app_dir(:midgard_platform, "priv/static/fonts/#{filename}")
      conn |> put_resp_content_type("font/ttf") |> send_resp(200, File.read!(path))
    else
      send_resp(conn, 404, "not found\n")
    end
  end

  match "/run/:slug/*tail" do
    case Workspace.read(slug) do
      {:ok, %{record: %{live: %{id: deployment}}}} ->
        invoke(conn, deployment, tail)

      _ ->
        send_resp(conn, 404, "worker not deployed\n")
    end
  end

  match _ do
    html(conn, Page.not_found(), 404)
  end

  defp invoke(conn, deployment, tail) do
    case read_request_body(conn, 32_768) do
      {:ok, body, conn} ->
        request = %Midgard.Request{
          method: conn.method,
          path: "/" <> Enum.join(tail, "/"),
          query_string: conn.query_string,
          headers: conn.req_headers,
          body: body
        }

        with {:ok, bytes} <- Midgard.Protocol.request(request),
             {:ok, reply} <- Midgard.Platform.call(deployment, bytes),
             {:ok, {status, payload}} <- Midgard.Protocol.decode_response(reply) do
          conn |> put_resp_content_type("text/plain", "utf-8") |> send_resp(status, payload)
        else
          {:error, :invalid_request} ->
            send_resp(conn, 400, "request exceeds worker protocol limits\n")

          {:error, :not_deployed} ->
            send_resp(conn, 503, "worker is restarting\n")

          _ ->
            send_resp(conn, 502, "worker invocation failed\n")
        end

      {:error, conn} ->
        send_resp(conn, 413, "request body exceeds 32 KiB\n")
    end
  end

  defp deploy_error(conn, slug, reason) do
    case Workspace.read(slug) do
      {:ok, %{source: source, record: record}} ->
        html(conn, Page.editor(slug, source, record, csrf(), conn.port, reason), 422)

      _ ->
        html(conn, Page.not_found(), 404)
    end
  end

  defp form(conn) do
    if get_req_header(conn, "content-type")
       |> Enum.any?(&String.starts_with?(&1, "application/x-www-form-urlencoded")) do
      case read_request_body(conn, 256_000) do
        {:ok, body, conn} ->
          try do
            {:ok, Plug.Conn.Query.decode(body, validate_utf8: true), conn}
          rescue
            _ -> {:error, "invalid form encoding", conn}
          end

        {:error, conn} ->
          {:error, "form exceeds 256 KiB", conn}
      end
    else
      {:error, "expected a form submission", conn}
    end
  end

  defp read_request_body(conn, limit) do
    case Plug.Conn.read_body(conn, length: limit + 1, read_length: limit + 1) do
      {:ok, body, conn} when byte_size(body) <= limit -> {:ok, body, conn}
      {_, _, conn} -> {:error, conn}
      _ -> {:error, conn}
    end
  end

  defp authorized(%{"csrf" => token}) when is_binary(token) do
    if Plug.Crypto.secure_compare(token, csrf()), do: :ok, else: {:error, "invalid form token"}
  end

  defp authorized(_), do: {:error, "missing form token"}
  defp csrf, do: :persistent_term.get({Midgard.Platform, :csrf})

  defp redirect(conn, path) do
    conn |> put_resp_header("location", path) |> send_resp(303, "")
  end

  defp html(conn, content, status \\ 200) do
    conn |> put_resp_content_type("text/html", "utf-8") |> send_resp(status, content)
  end

  defp local_request(conn, _options) do
    conn =
      conn
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("referrer-policy", "no-referrer")
      |> put_resp_header(
        "content-security-policy",
        "default-src 'self'; img-src 'self'; style-src 'self'; script-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"
      )

    if conn.host in ["127.0.0.1", "localhost"] do
      conn
    else
      conn |> send_resp(403, "local host only\n") |> halt()
    end
  end
end
