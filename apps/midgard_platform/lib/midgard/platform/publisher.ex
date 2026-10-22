defmodule Midgard.Platform.Publisher do
  @moduledoc """
  Serializes revisions per worker and publishes a URL only after atomic native
  admission. A failed compile or load leaves the preceding revision callable.
  """
  require Logger
  alias Packer.ShipmentUpload
  alias Midgard.Platform.{Compiler, Shipment, Workspace}

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

  def deploy_uploaded(%ShipmentUpload{application: application} = upload, slug \\ nil) do
    slug = slug || application

    with :ok <- Workspace.begin_upload(slug) do
      try do
        publish_upload(slug, upload)
      after
        release_busy(slug)
      end
    end
  end

  defp publish_upload(slug, upload) do
    revision = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    id = "#{slug}-#{revision}"
    destination = Path.join([Workspace.root(), "artifacts", "#{id}.midgard"])

    try do
      with :ok <- ShipmentUpload.write(upload, destination),
           {:ok, shipment} <- Shipment.read(destination),
           :ok <- uploaded_application(shipment, upload.application),
           {:ok, digest} <- admit_upload(id, destination, shipment.digest) do
        live = %{
          id: id,
          digest: digest,
          modules: length(shipment.modules),
          protocol: shipment.protocol,
          language: shipment.language,
          artifact: destination,
          deployed_at: DateTime.utc_now()
        }

        case Workspace.finish_deploy(slug, {:ok, live}) do
          {:ok, previous} ->
            if previous, do: reclaim(previous.id)
            {:ok, live}

          error ->
            reclaim(id)
            error
        end
      else
        {:error, %Libbeam.Error{} = reason} -> {:error, reason.message}
        {:error, reason} -> {:error, reason}
        _ -> {:error, "uploaded shipment was rejected"}
      end
    after
      # Only the exact shipment that was admitted is retained. Rejected uploads
      # cannot be published as a stored but falsely live revision.
      case Workspace.read(slug) do
        {:ok, %{record: %{live: %{id: ^id}}}} -> :ok
        _ -> File.rm_rf(destination)
      end
    end
  end

  @doc "Stops an uploaded worker's live isolate and deletes its artifact."
  def remove(slug) do
    with {:ok, live} <- Workspace.remove(slug) do
      if live do
        reclaim(live.id)
        File.rm_rf(live.artifact)
      end

      :ok
    end
  end

  defp uploaded_application(%Shipment{application: slug}, slug), do: :ok
  defp uploaded_application(_, _), do: {:error, "shipment application does not match its URL"}

  defp admit_upload(id, destination, expected) do
    case Midgard.Platform.deploy(id, destination, defer_denied_nif: true) do
      {:ok, ^expected} ->
        {:ok, expected}

      {:ok, _other} ->
        reclaim(id)
        {:error, "shipment changed during native admission"}

      error ->
        error
    end
  end

  defp publish(slug, source) do
    revision = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    id = "#{slug}-#{revision}"
    root = Workspace.root()
    destination = Path.join([root, "artifacts", "#{id}.midgard"])

    with {:ok, %{digest: digest, modules: count}} <- Compiler.compile(slug, source, destination),
         {:ok, ^digest} <- Midgard.Platform.deploy(id, destination, defer_denied_nif: true) do
      live = %{
        id: id,
        digest: digest,
        modules: count,
        protocol: :midgard,
        language: :elixir,
        artifact: destination,
        deployed_at: DateTime.utc_now()
      }

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
