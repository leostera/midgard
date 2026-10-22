defmodule Mix.Tasks.Midgard.Logout do
  use Mix.Task
  alias Midgard.CLI.Credentials

  @shortdoc "Revoke the saved Midgard CLI token"

  @impl true
  def run([]) do
    case Credentials.delete() do
      :ok -> Mix.shell().info("Signed out of Midgard.")
      {:error, reason} -> Mix.raise("Could not remove credentials: #{inspect(reason)}")
    end
  end

  def run(_), do: Mix.raise("Usage: mix midgard.logout")
end
