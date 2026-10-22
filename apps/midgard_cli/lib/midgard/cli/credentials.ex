defmodule Midgard.CLI.Credentials do
  @moduledoc false

  def path do
    Path.join(:filename.basedir(:user_config, "midgard") |> List.to_string(), "credentials.json")
  end

  def read do
    with {:ok, bytes} <- File.read(path()),
         %{"endpoint" => endpoint, "token" => token, "email" => email} <- :json.decode(bytes),
         true <- is_binary(endpoint) and is_binary(token) and is_binary(email) do
      {:ok, %{endpoint: endpoint, token: token, email: email}}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def write(credentials) do
    path = path()
    directory = Path.dirname(path)

    with :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, 0o700),
         :ok <- File.write(path, :json.encode(credentials), [:binary]),
         :ok <- File.chmod(path, 0o600) do
      :ok
    end
  end

  def delete do
    case read() do
      {:ok, %{endpoint: endpoint, token: token}} -> revoke(endpoint, token)
      :error -> :ok
    end

    case File.rm(path()) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  defp revoke(endpoint, token) do
    ensure_http_started()
    uri = URI.parse(endpoint)
    url = String.to_charlist(endpoint <> "/api/logout")
    headers = [{~c"authorization", String.to_charlist("Bearer " <> token)}]

    options = [
      timeout: 10_000,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: String.to_charlist(uri.host)
      ]
    ]

    :httpc.request(:post, {url, headers, ~c"application/json", ~c"{}"}, options, [])
    :ok
  rescue
    _ -> :ok
  end

  defp ensure_http_started do
    Application.ensure_all_started(:ssl)
    Application.ensure_all_started(:inets)
  end
end
