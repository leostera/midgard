defmodule Midgard.Platform.Publisher do
  @moduledoc """
  Serializes revisions per worker and publishes a URL only after atomic native
  admission. A failed compile or load leaves the preceding revision callable.
  """
  require Logger
  alias Midgard.Platform.{Compiler, Workspace}

  def deploy(slug, source) do
    with :ok <- Workspace.begin_deploy(slug, source) do
      try do
        publish(slug, source)
      after
        # A failed build never replaces the last successfully published handle.
        # The successful branch commits its new handle before leaving this scope.
        release_busy(slug)
      end
    end
  end

  defp publish(slug, source) do
    revision = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    id = "#{slug}-#{revision}"
    root = Workspace.root()
    destination = Path.join([root, "artifacts", "#{id}.midgard"])

    with {:ok, %{digest: digest, modules: count}} <- Compiler.compile(slug, source, destination),
         {:ok, ^digest} <- Midgard.Platform.deploy(id, destination, defer_denied_nif: true) do
      live = %{id: id, digest: digest, modules: count, artifact: destination}

      case Workspace.finish_deploy(slug, {:ok, live}) do
        {:ok, previous} ->
          if previous, do: reclaim(previous.id)
          {:ok, live}

        error ->
          reclaim(id)
          error
      end
    else
      {:ok, _different_digest} ->
        reclaim(id)
        File.rm_rf(destination)
        {:error, "shipment changed between compilation and admission"}

      {:error, reason} = error ->
        File.rm_rf(destination)
        if match?(%Libbeam.Error{}, reason), do: {:error, reason.message}, else: error
    end
  end

  defp reclaim(id) do
    case Midgard.Platform.stop(id) do
      :ok -> :ok
      {:error, reason} -> Logger.error("Isolate #{id} could not be reclaimed: #{inspect(reason)}")
    end
  end

  defp release_busy(slug) do
    case Workspace.read(slug) do
      {:ok, %{record: %{busy: true}}} -> Workspace.finish_deploy(slug, :failed)
      _ -> :ok
    end
  end
end
