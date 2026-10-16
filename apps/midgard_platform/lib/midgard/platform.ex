defmodule Midgard.Platform do
  @moduledoc """
  Single-container libbeam control plane. It owns one supervised native Engine,
  with an Isolate per deployment. HTTP routing and artifact storage are separate
  boundaries; this module only accepts a local verified shipment directory and
  dispatches already-framed binary requests.
  """
  use Supervisor
  alias Libbeam.Isolate
  alias Midgard.Platform.{Deployments, Shipment}

  def start_link(options \\ []), do: Supervisor.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(options) do
    engine_options = Keyword.take(options, [:executable]) ++ [name: Midgard.Platform.NativeEngine]

    children = [
      {Libbeam.Engine, engine_options},
      {Deployments, engine: Midgard.Platform.NativeEngine}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  def deploy(id, artifact_directory, options \\ []) do
    with {:ok, shipment} <- Shipment.read(artifact_directory) do
      Deployments.deploy(id, shipment, options)
    end
  end

  def call(id, request) when is_binary(request) do
    with {:ok, deployment} <- Deployments.lookup(id) do
      Isolate.call(deployment.isolate, deployment.module, deployment.function, request)
    end
  end

  def call(_, _), do: {:error, :invalid_request_bytes}

  def stop(id), do: Deployments.stop(id)
end
