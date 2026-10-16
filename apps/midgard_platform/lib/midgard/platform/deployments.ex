defmodule Midgard.Platform.Deployments do
  @moduledoc """
  One container's deployment registry. Atomic libbeam group admission precedes
  publication; a failed load is reclaimed and never receives traffic.
  """
  use GenServer
  alias Libbeam.{Engine, Isolate}
  alias Midgard.Platform.Shipment

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  def deploy(id, %Shipment{} = shipment, options \\ []),
    do: GenServer.call(__MODULE__, {:deploy, id, shipment, options}, :infinity)

  def lookup(id), do: GenServer.call(__MODULE__, {:lookup, id})
  def stop(id), do: GenServer.call(__MODULE__, {:stop, id}, :infinity)

  @impl true
  def init(options) do
    engine = Keyword.fetch!(options, :engine)
    {:ok, %{engine: engine, deployments: %{}}}
  end

  @impl true
  def handle_call({:deploy, id, shipment, options}, _from, state) do
    cond do
      not valid_id?(id) ->
        {:reply, {:error, :invalid_deployment_id}, state}

      Map.has_key?(state.deployments, id) ->
        {:reply, {:error, :already_deployed}, state}

      not Keyword.keyword?(options) or
        Keyword.keys(options) -- [:memory_limit_bytes, :invocation_work_limit, :defer_denied_nif] !=
          [] or
          Keyword.get(options, :defer_denied_nif, false) not in [true, false] ->
        {:reply, {:error, :invalid_deployment_options}, state}

      true ->
        {load_options, limits} = Keyword.split(options, [:defer_denied_nif])

        case Engine.create_isolate(state.engine, limits) do
          {:ok, isolate} -> admit(state, id, shipment, isolate, load_options)
          {:error, error} -> {:reply, {:error, error}, state}
        end
    end
  end

  def handle_call({:lookup, id}, _from, state) do
    case Map.fetch(state.deployments, id) do
      {:ok, deployment} -> {:reply, {:ok, deployment}, state}
      :error -> {:reply, {:error, :not_deployed}, state}
    end
  end

  def handle_call({:stop, id}, _from, state) do
    case Map.fetch(state.deployments, id) do
      {:ok, deployment} ->
        case Isolate.stop(deployment.isolate) do
          :ok -> {:reply, :ok, %{state | deployments: Map.delete(state.deployments, id)}}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      :error ->
        {:reply, {:error, :not_deployed}, state}
    end
  end

  defp admit(state, id, shipment, isolate, load_options) do
    case Isolate.load_modules(isolate, shipment.modules, load_options) do
      :ok ->
        deployment = %{
          isolate: isolate,
          module: shipment.module,
          function: shipment.function,
          digest: shipment.digest
        }

        {:reply, {:ok, deployment.digest},
         %{state | deployments: Map.put(state.deployments, id, deployment)}}

      {:error, reason} ->
        case Isolate.stop(isolate) do
          :ok ->
            {:reply, {:error, reason}, state}

          {:error, stop_reason} ->
            {:stop, {:unreclaimed_failed_load, stop_reason}, {:error, reason}, state}
        end
    end
  end

  defp valid_id?(id), do: is_binary(id) and byte_size(id) in 1..128
end
