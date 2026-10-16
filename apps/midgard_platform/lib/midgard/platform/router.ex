defmodule Midgard.Platform.Router do
  @moduledoc "Local-only editor, deployment actions and callable worker URLs."
  use Plug.Router
  require Logger
  alias Packer.ShipmentUpload
  alias Midgard.Platform.{Page, Publisher, Workspace}

  plug(:local_request)
  plug(:match)
  plug(:dispatch)

  get "/" do
    if byte_size(conn.query_string) <= 512 do
      conn = Plug.Conn.fetch_query_params(conn)
      html(conn, Page.index(Workspace.list(), conn.query_params))
    else
      send_resp(conn, 400, "filter query too long\n")
    end
  end

  get "/workers/new" do
    html(conn, Page.deploy_guide())
  end

  post "/workers" do
    with {:ok, fields, conn} <- form(conn),
         :ok <- authorized(fields),
         :ok <- Workspace.create(fields["name"]) do
      publish_new(conn, fields["name"])
    else
      {:error, reason, conn} -> html(conn, Page.new_worker(csrf(), reason), 422)
      {:error, reason} -> html(conn, Page.new_worker(csrf(), reason), 422)
    end
  end

  get "/workers/:slug" do
    case Workspace.read(slug) do
      {:ok, %{record: %{origin: :cli} = record}} ->
        html(conn, Page.uploaded_worker(slug, record, conn.port))

      {:ok, %{source: source, record: record}} ->
        html(
          conn,
          Page.editor(slug, source, record, csrf(), conn.port, nil, conn.assigns.style_nonce)
        )

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

  post "/api/deployments/:slug" do
    upload_shipment(conn, slug)
  end

  get "/assets/app.css" do
    path = Application.app_dir(:midgard_platform, "priv/static/app.css")
    conn |> put_resp_content_type("text/css") |> send_resp(200, File.read!(path))
  end

  get "/assets/editor.js" do
    path = Application.app_dir(:midgard_platform, "priv/static/editor.js")
    conn |> put_resp_content_type("text/javascript") |> send_resp(200, File.read!(path))
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
        invoke(conn, slug, deployment, tail)

      _ ->
        send_resp(conn, 404, "worker not deployed\n")
    end
  end

  match _ do
    html(conn, Page.not_found(), 404)
  end

  defp upload_shipment(conn, slug) do
    with {:ok, route} <- upload_request(conn, slug),
         {:ok, bytes, conn} <- read_request_body(conn, ShipmentUpload.max_wire()),
         {:ok, %ShipmentUpload{application: ^slug} = upload} <- ShipmentUpload.parse(bytes),
         {:ok, live} <- Publisher.deploy_uploaded(upload, route) do
      body =
        :json.encode(%{
          slug: route,
          digest: live.digest,
          modules: live.modules,
          path: "/run/#{route}/"
        })
        |> IO.iodata_to_binary()

      conn |> put_resp_content_type("application/json") |> send_resp(201, body)
    else
      {:error, %Plug.Conn{} = conn} -> send_resp(conn, 413, "shipment upload exceeds 34 MB\n")
      {:error, :unauthorized} -> send_resp(conn, 401, "deployment token required\n")
      {:error, reason} -> send_resp(conn, 422, "shipment rejected: #{inspect(reason)}\n")
      _ -> send_resp(conn, 422, "shipment application does not match worker name\n")
    end
  end

  defp upload_request(conn, app) do
    cond do
      not Workspace.valid_slug?(app) ->
        {:error, :invalid_name}

      get_req_header(conn, "content-type") != [ShipmentUpload.content_type()] ->
        {:error, :invalid_content_type}

      get_req_header(conn, "origin") != [] ->
        {:error, :browser_upload_not_supported}

      System.get_env("MIDGARD_CONTAINER_HTTP") == "1" ->
        public_upload_route(conn, app)

      true ->
        token = System.get_env("MIDGARD_DEPLOY_TOKEN")

        if token &&
             (byte_size(token) < 32 or
                not upload_token?(get_req_header(conn, "authorization"), token)) do
          {:error, :unauthorized}
        else
          {:ok, app}
        end
    end
  end

  defp public_upload_route(conn, app) do
    gateway = System.get_env("MIDGARD_INTERNAL_UPLOAD_KEY")
    route = get_req_header(conn, "x-midgard-public-route")
    supplied = get_req_header(conn, "x-midgard-internal-upload")
    prefix = String.slice(app, 0, 23) <> "_"

    if is_binary(gateway) and byte_size(gateway) >= 32 and
         upload_token?(supplied, gateway) and
         match?([_], route) and
         String.starts_with?(hd(route), prefix) and
         Regex.match?(~r/\A[a-z][a-z0-9_]*_[0-9a-f]{16}\z/, hd(route)) and
         Workspace.valid_slug?(hd(route)) do
      {:ok, hd(route)}
    else
      {:error, :unauthorized}
    end
  end

  defp upload_token?(["Bearer " <> supplied], expected) do
    actual = :crypto.hash(:sha256, supplied)
    wanted = :crypto.hash(:sha256, expected)
    Plug.Crypto.secure_compare(actual, wanted)
  end

  defp upload_token?(_, _), do: false

  defp invoke(conn, slug, deployment, tail) do
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
             {:ok, reply} <- call_worker(slug, deployment, bytes),
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

  defp call_worker(slug, deployment, bytes) do
    result = Midgard.Platform.call(deployment, bytes)

    # A missing Isolate is not an invocation. Telemetry failure never changes
    # the HTTP outcome of a call that did reach the native deployment registry.
    unless result == {:error, :not_deployed} do
      case Workspace.record_invocation(slug) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Could not record invocation for #{slug}: #{inspect(reason)}")
      end
    end

    result
  end

  defp publish_new(conn, slug) do
    case Workspace.read(slug) do
      {:ok, %{source: source}} ->
        case Publisher.deploy(slug, source) do
          {:ok, _live} -> redirect(conn, "/workers/#{slug}")
          {:error, reason} -> deploy_error(conn, slug, reason)
        end

      {:error, reason} ->
        html(conn, Page.new_worker(csrf(), reason), 422)
    end
  end

  defp deploy_error(conn, slug, reason) do
    case Workspace.read(slug) do
      {:ok, %{source: source, record: record}} ->
        html(
          conn,
          Page.editor(slug, source, record, csrf(), conn.port, reason, conn.assigns.style_nonce),
          422
        )

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
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    conn =
      conn
      |> assign(:style_nonce, nonce)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("referrer-policy", "no-referrer")
      |> put_resp_header(
        "content-security-policy",
        "default-src 'self'; img-src 'self'; style-src 'self' 'nonce-#{nonce}'; script-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"
      )

    if conn.host in ["127.0.0.1", "localhost"] do
      conn
    else
      conn |> send_resp(403, "local host only\n") |> halt()
    end
  end
end
