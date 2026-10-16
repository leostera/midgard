defmodule Midgard.Platform.Application do
  @moduledoc false
  use Application
  require Logger

  @default_serve Mix.env() != :test

  @impl true
  def start(_type, _args) do
    if Application.get_env(:midgard_platform, :serve, @default_serve) do
      root =
        System.get_env("MIDGARD_WORKSPACE") ||
          Path.expand(".midgard-platform", File.cwd!())

      Application.put_env(:midgard_platform, :workspace, root)
      port = port!()
      token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      :persistent_term.put({Midgard.Platform, :csrf}, token)

      children = [
        {Midgard.Platform, []},
        {Midgard.Platform.Workspace, root: root},
        {Bandit,
         plug: Midgard.Platform.Router,
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: port,
         startup_log: false}
      ]

      result =
        Supervisor.start_link(children,
          strategy: :rest_for_one,
          name: Midgard.Platform.LocalServer
        )

      if match?({:ok, _}, result) do
        Logger.info(
          "Midgard local platform ready at http://127.0.0.1:#{port} (trusted local use only)"
        )
      end

      result
    else
      Supervisor.start_link([], strategy: :one_for_one, name: Midgard.Platform.LocalServer)
    end
  end

  defp port! do
    case Integer.parse(System.get_env("MIDGARD_PORT") || "4000") do
      {port, ""} when port in 1..65_535 -> port
      _ -> raise "MIDGARD_PORT must be a TCP port in 1..65535"
    end
  end
end
