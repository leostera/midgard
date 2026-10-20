defmodule Mix.Tasks.Midgard.Deploy do
  use Mix.Task
  alias Packer.ShipmentUpload
  # Supplied by the worker project's Mix dependencies, not by this archive.
  @compile {:no_warn_undefined, ShipmentUpload}

  @shortdoc "Builds locally and uploads an exact BEAM shipment for native admission"
  @default_endpoint "https://midgard.leostera.dev"

  @impl true
  def run(args) do
    {options, positional, invalid} =
      OptionParser.parse(args,
        strict: [endpoint: :string, artifact: :string, output: :string]
      )

    if positional != [] or invalid != [] do
      Mix.raise("Usage: mix midgard.deploy [--endpoint URL] [--artifact DIR] [--output DIR]")
    end

    if options[:artifact] && options[:output] do
      Mix.raise("--artifact and --output cannot be used together")
    end

    endpoint =
      endpoint!(options[:endpoint] || System.get_env("MIDGARD_ENDPOINT") || @default_endpoint)

    token = System.get_env("MIDGARD_DEPLOY_TOKEN")

    if is_nil(token) and endpoint.host not in ["localhost", "127.0.0.1", "midgard.leostera.dev"] do
      Mix.raise("Set MIDGARD_DEPLOY_TOKEN before deploying to a custom remote host")
    end

    path = options[:artifact] || options[:output] || "#{Mix.Project.config()[:app]}.midgard"

    if options[:artifact] do
      # Load project dependencies when available, but allow standalone CLI use
      # from a non-Mix build such as a Rebar3 project.
      if Mix.Project.get(), do: Mix.Task.run("compile")
    else
      build_args = if options[:output], do: ["--output", options[:output]], else: []
      Mix.Task.run("midgard.build", build_args)
    end

    unless Code.ensure_loaded?(ShipmentUpload) do
      Mix.raise("Add the Packer dependency and run mix deps.get before deploying")
    end

    with {:ok, upload} <- ShipmentUpload.read_directory(path),
         :ok <- wait_for_public_runtime(endpoint),
         url <- URI.to_string(endpoint) <> "/api/deployments/#{upload.application}",
         {:ok, response} <- post(url, ShipmentUpload.encode(upload), token),
         {:ok, result} <- parse_response(response, upload.application) do
      Mix.shell().info(
        "Deployed #{result["slug"]} · #{result["modules"]} BEAMs · #{url |> URI.parse() |> Map.get(:host)}"
      )

      route_prefix =
        if String.starts_with?(result["path"], "https://"),
          do: result["path"],
          else: "#{URI.to_string(endpoint)}#{result["path"]}"

      Mix.shell().info("Worker URL: #{route_prefix}")
      Mix.shell().info(call_hint(upload.manifest, route_prefix))
    else
      {:error, reason} -> Mix.raise("Midgard deployment failed: #{inspect(reason)}")
    end
  end

  defp call_hint(manifest_bytes, route_prefix) do
    case :json.decode(manifest_bytes) do
      %{"entrypoint" => %{"protocol" => "raw.bytes.v1"}} ->
        "Browser text preview: GET #{route_prefix}\nRaw-byte example: curl -X POST --data-binary 'hello' '#{route_prefix}'"

      _ ->
        "Append a path implemented by your worker (generated workers use GET #{route_prefix}hello)"
    end
  end

  defp endpoint!(input) do
    case URI.parse(input) do
      %URI{scheme: scheme, host: host, path: path, userinfo: nil, query: nil, fragment: nil} = uri
      when scheme in ["http", "https"] and is_binary(host) and path in [nil, "", "/"] ->
        if scheme == "http" and host not in ["localhost", "127.0.0.1"] do
          Mix.raise("HTTP deployment is allowed only to local loopback")
        end

        %{uri | path: nil}

      _ ->
        Mix.raise("--endpoint must be a bare HTTPS origin or a local loopback HTTP origin")
    end
  end

  defp wait_for_public_runtime(%URI{host: host} = endpoint) when host == "midgard.leostera.dev" do
    ensure_http_started()
    url = String.to_charlist(URI.to_string(endpoint) <> "/api/deployments/ready")
    options = [timeout: 25_000] ++ ssl_options(endpoint)
    Mix.shell().info("Checking public runtime before upload...")
    wait_for_public_runtime(url, options, 8)
  end

  defp wait_for_public_runtime(_endpoint), do: :ok

  defp wait_for_public_runtime(_url, _options, 0),
    do: {:error, "Public runtime did not become ready; shipment was not uploaded"}

  defp wait_for_public_runtime(url, options, attempts) do
    case :httpc.request(:get, {url, []}, options, body_format: :binary) do
      {:ok, {{_, 204, _}, _, _}} ->
        :ok

      {:ok, {{_, status, _}, _, _}} when status in [502, 503] ->
        Process.sleep(3_000)
        wait_for_public_runtime(url, options, attempts - 1)

      {:error, reason} when reason in [:timeout, :socket_closed_remotely] ->
        Process.sleep(3_000)
        wait_for_public_runtime(url, options, attempts - 1)

      {:ok, {{_, status, _}, _, _}} ->
        {:error, "Public runtime readiness returned HTTP #{status}; shipment was not uploaded"}

      {:error, reason} ->
        {:error, "Public runtime readiness failed: #{inspect(reason)}; shipment was not uploaded"}
    end
  end

  defp ensure_http_started do
    # An archive is loaded by Mix as a plugin, not started as an OTP app.
    # Its :extra_applications therefore do not put optional OTP libraries on
    # the code path in a fresh worker project.
    for app <- [:asn1, :public_key, :ssl, :inets] do
      root = List.to_string(:code.lib_dir())

      case Path.wildcard(Path.join([root, "#{app}-*", "ebin"])) do
        [path] -> true = :code.add_pathz(String.to_charlist(path))
        _ -> Mix.raise("Missing OTP application #{app} required for HTTP upload")
      end
    end

    {:ok, _} = Application.ensure_all_started(:ssl)
    {:ok, _} = Application.ensure_all_started(:inets)
  end

  defp ssl_options(%URI{scheme: "https", host: host}) do
    [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: String.to_charlist(host),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]
  end

  defp ssl_options(_uri), do: []

  defp post(url, bytes, token) do
    ensure_http_started()
    headers = [{~c"content-type", String.to_charlist(ShipmentUpload.content_type())}]

    headers =
      if token,
        do: [{~c"authorization", String.to_charlist("Bearer " <> token)} | headers],
        else: headers

    uri = URI.parse(url)

    case :httpc.request(
           :post,
           {String.to_charlist(url), headers, String.to_charlist(ShipmentUpload.content_type()),
            bytes},
           [timeout: 120_000] ++ ssl_options(uri),
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, _, body}} -> {:ok, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_response({201, body}, app) do
    case :json.decode(body) do
      %{"slug" => slug, "digest" => digest, "modules" => count, "path" => path} = result
      when is_binary(slug) and is_binary(digest) and is_integer(count) and count in 1..512 and
             is_binary(path) ->
        expected_local_path = "/run/#{slug}/"
        expected_public_url = "https://#{String.replace(slug, "_", "-")}.midgard.leostera.dev/"

        if (slug == app or
              (String.starts_with?(slug, String.slice(app, 0, 23) <> "_") and
                 String.match?(slug, ~r/\A[a-z][a-z0-9_]*_[0-9a-f]{16}\z/))) and
             path in [expected_local_path, expected_public_url] and
             String.match?(digest, ~r/\A[0-9a-f]{64}\z/) do
          {:ok, result}
        else
          {:error, :invalid_deployment_response}
        end

      _ ->
        {:error, :invalid_deployment_response}
    end
  rescue
    _ -> {:error, :invalid_deployment_response}
  end

  defp parse_response({status, body}, _app) do
    {:error,
     "server returned HTTP #{status}: #{String.slice(String.replace_invalid(body), 0, 512)}"}
  end
end
