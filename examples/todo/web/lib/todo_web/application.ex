defmodule TodoWeb.Application do
  @moduledoc "Local-only supervisor: an Erlang store and a loopback HTTP listener."
  use Application

  @impl true
  def start(_type, _args) do
    store = %{id: :todo_store, start: {:todo_store, :start_link, []}}

    children =
      if Mix.env() == :test do
        [store]
      else
        csrf_token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

        [
          store,
          {Bandit,
           plug: {TodoWeb.Router, csrf_token: csrf_token},
           scheme: :http,
           ip: {127, 0, 0, 1},
           port: local_port()}
        ]
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: TodoWeb.Supervisor)
  end

  defp local_port do
    case Integer.parse(System.get_env("TODO_PORT") || "4100") do
      {port, ""} when port in 1..65_535 -> port
      _ -> raise "TODO_PORT must be a TCP port from 1 to 65535"
    end
  end
end
