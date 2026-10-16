defmodule Libbeam.Supervisor do
  @moduledoc "Dynamically supervises Engine Port owners; Isolates never survive an Engine restart."
  use DynamicSupervisor

  def start_link(options \\ []),
    do: DynamicSupervisor.start_link(__MODULE__, :ok, options)

  def start_engine(supervisor, options \\ []),
    do: DynamicSupervisor.start_child(supervisor, {Libbeam.Engine, options})

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)
end
