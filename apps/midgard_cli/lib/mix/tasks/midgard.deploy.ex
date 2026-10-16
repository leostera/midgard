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

    unless Code.ensure_loaded?(ShipmentUpload) do
      Mix.raise("Add the Packer dependency and run mix deps.get before deploying")
    end

    if options[:artifact] && options[:output] do
      Mix.raise("--artifact and --output cannot be used together")
    end

    endpoint =
      endpoint!(options[:endpoint] || System.get_env("MIDGARD_ENDPOINT") || @default_endpoint)

    token = System.get_env("MIDGARD_DEPLOY_TOKEN")

    if is_nil(token) and endpoint.host not in ["localhost", "127.0.0.1"] do
      Mix.raise("Set MIDGARD_DEPLOY_TOKEN before deploying to a remote host")
    end

    path = options[:artifact] || options[:output] || "#{Mix.Project.config()[:app]}.midgard"

    unless options[:artifact] do
      build_args = if options[:output], do: ["--output", options[:output]], else: []
      Mix.Task.run("midgard.build", build_args)
    end

    with {:ok, upload} <- ShipmentUpload.read_directory(path),
         url <- URI.to_string(endpoint) <> "/api/deployments/#{upload.application}",
         {:ok, response} <- post(url, ShipmentUpload.encode(upload), token),
         {:ok, result} <- parse_response(response, upload.application) do
      Mix.shell().info(
        "Deployed #{result["slug"]} · #{result["modules"]} BEAMs · #{url |> URI.parse() |> Map.get(:host)}"
      )

      Mix.shell().info("Route: #{URI.to_string(endpoint)}/run/#{upload.application}/")
    else
      {:error, reason} -> Mix.raise("Midgard deployment failed: #{inspect(reason)}")
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

  defp post(url, bytes, token) do
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
    headers = [{~c"content-type", String.to_charlist(ShipmentUpload.content_type())}]

    headers =
      if token,
        do: [{~c"authorization", String.to_charlist("Bearer " <> token)} | headers],
        else: headers

    uri = URI.parse(url)

    ssl =
      if uri.scheme == "https",
        do: [
          ssl: [
            verify: :verify_peer,
            cacerts: :public_key.cacerts_get(),
            server_name_indication: String.to_charlist(uri.host),
            customize_hostname_check: [
              match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
            ]
          ]
        ],
        else: []

    case :httpc.request(
           :post,
           {String.to_charlist(url), headers, String.to_charlist(ShipmentUpload.content_type()),
            bytes},
           [timeout: 120_000] ++ ssl,
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, _, body}} -> {:ok, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_response({201, body}, app) do
    case :json.decode(body) do
      %{"slug" => ^app, "digest" => digest, "modules" => count, "path" => path} = result
      when is_binary(digest) and is_integer(count) and count in 1..512 and is_binary(path) ->
        {:ok, result}

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
