defmodule Mix.Tasks.Midgard.Login do
  use Mix.Task
  alias Midgard.CLI.Credentials

  @shortdoc "Sign in to Midgard with an email code"
  @endpoint "https://midgard.leostera.dev"

  @impl true
  def run(args) do
    {options, positional, invalid} = OptionParser.parse(args, strict: [endpoint: :string])

    if positional != [] or invalid != [] do
      Mix.raise("Usage: mix midgard.login [--endpoint https://midgard.leostera.dev]")
    end

    endpoint =
      String.trim_trailing(
        options[:endpoint] || System.get_env("MIDGARD_ENDPOINT") || @endpoint,
        "/"
      )

    email = prompt("Email: ") |> String.trim()
    start = post(endpoint <> "/api/login/start", %{"email" => email})
    if start != :ok, do: Mix.raise("Could not request a sign-in code: #{inspect(start)}")

    Mix.shell().info("We sent a code to #{email}.")
    code = prompt("Code: ") |> String.trim()

    case post(endpoint <> "/api/login/verify", %{
           "email" => email,
           "code" => code,
           "client" => "cli"
         }) do
      {:ok, %{"token" => token, "email" => verified}} when is_binary(token) ->
        credentials = %{"endpoint" => endpoint, "token" => token, "email" => verified}

        case Credentials.write(credentials) do
          :ok ->
            Mix.shell().info(
              "Signed in as #{verified}. Credentials saved to #{Credentials.path()}."
            )

          {:error, reason} ->
            Mix.raise("Could not save credentials: #{inspect(reason)}")
        end

      error ->
        Mix.raise("Sign-in failed: #{inspect(error)}")
    end
  end

  defp prompt(message) do
    case IO.gets(message) do
      nil -> Mix.raise("Input ended before sign-in completed")
      value -> value
    end
  end

  defp post(url, payload) do
    Application.ensure_all_started(:ssl)
    Application.ensure_all_started(:inets)
    uri = URI.parse(url)
    headers = [{~c"content-type", ~c"application/json"}]
    body = :json.encode(payload)

    options = [
      timeout: 15_000,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: String.to_charlist(uri.host)
      ]
    ]

    case :httpc.request(
           :post,
           {String.to_charlist(url), headers, ~c"application/json", body},
           options, body_format: :binary) do
      {:ok, {{_, status, _}, _, response}} when status in 200..299 ->
        {:ok, :json.decode(response)}

      {:ok, {{_, status, _}, _, response}} ->
        {:error, "HTTP #{status}: #{String.slice(response, 0, 200)}"}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end
end
