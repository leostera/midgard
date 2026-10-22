defmodule Midgard.Platform.Workspace do
  @moduledoc """
  Trusted-local source workspace. The only persistent files are bounded source
  drafts, per-worker invocation totals, and immutable deployment artifacts;
  running handles never survive an
  Engine restart and therefore are deliberately not restored from disk.
  """
  use GenServer
  alias Midgard.Platform.Traffic
  @max_source 65_536
  @slug ~r/\A[a-z][a-z0-9_]{0,39}\z/

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)
  def list, do: GenServer.call(__MODULE__, :list)
  def read(slug), do: GenServer.call(__MODULE__, {:read, slug})
  def create(slug), do: GenServer.call(__MODULE__, {:create, slug})
  def begin_upload(slug), do: GenServer.call(__MODULE__, {:begin_upload, slug})
  def begin_deploy(slug, source), do: GenServer.call(__MODULE__, {:begin_deploy, slug, source})
  def finish_deploy(slug, result), do: GenServer.call(__MODULE__, {:finish_deploy, slug, result})
  def record_invocation(slug), do: GenServer.call(__MODULE__, {:record_invocation, slug})

  @doc "Forgets an uploaded worker that is not deploying; returns its live handle."
  def remove(slug), do: GenServer.call(__MODULE__, {:remove, slug})

  def root, do: Application.fetch_env!(:midgard_platform, :workspace)
  def valid_slug?(slug), do: is_binary(slug) and Regex.match?(@slug, slug)

  @impl true
  def init(options) do
    root = Keyword.fetch!(options, :root)
    File.mkdir_p!(Path.join(root, "workers"))
    File.mkdir_p!(Path.join(root, "artifacts"))

    workers =
      root
      |> Path.join("workers")
      |> File.ls!()
      |> Enum.filter(&valid_slug?/1)
      |> Enum.filter(fn slug ->
        case File.lstat(source_path(root, slug)) do
          {:ok, %{type: :regular, size: size}} when size in 1..@max_source -> true
          _ -> false
        end
      end)
      |> Map.new(fn slug ->
        origin =
          if File.read(Path.join([root, "workers", slug, "origin"])) == {:ok, "cli\n"},
            do: :cli,
            else: :local

        {slug, %{live: nil, busy: false, origin: origin}}
      end)

    registry = Process.whereis(Midgard.Platform.Deployments)
    monitor = if registry, do: Process.monitor(registry)
    if is_nil(registry), do: Process.send_after(self(), :watch_registry, 20)
    {:ok, %{root: root, workers: workers, registry_monitor: monitor}}
  end

  @impl true
  def handle_call(:list, _from, state) do
    rows =
      state.workers
      |> Enum.map(fn {slug, item} ->
        traffic =
          case Traffic.read(state.root, slug) do
            {:ok, data} -> data
            {:error, _} -> %{invocations: nil, last_invoked_at: nil}
          end

        Map.merge(%{slug: slug, live: item.live, busy: item.busy}, traffic)
      end)
      |> Enum.sort_by(& &1.slug)

    {:reply, rows, state}
  end

  def handle_call({:read, slug}, _from, state) do
    if valid_slug?(slug) and Map.has_key?(state.workers, slug) do
      case File.read(source_path(state.root, slug)) do
        {:ok, bytes} ->
          traffic =
            case Traffic.read(state.root, slug) do
              {:ok, data} -> data
              {:error, _} -> %{invocations: nil, last_invoked_at: nil}
            end

          record = Map.merge(state.workers[slug], traffic)
          {:reply, {:ok, %{source: bytes, record: record}}, state}

        _ ->
          {:reply, {:error, :source_unavailable}, state}
      end
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:record_invocation, slug}, _from, state) do
    if valid_slug?(slug) and Map.has_key?(state.workers, slug) do
      {:reply, Traffic.record(state.root, slug), state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:create, slug}, _from, state) do
    cond do
      not valid_slug?(slug) ->
        {:reply, {:error, :invalid_name}, state}

      Map.has_key?(state.workers, slug) ->
        {:reply, {:error, :already_exists}, state}

      true ->
        path = Path.join([state.root, "workers", slug])

        case File.mkdir(path) do
          :ok ->
            File.write!(source_path(state.root, slug), template(slug))
            workers = Map.put(state.workers, slug, %{live: nil, busy: false, origin: :local})
            {:reply, :ok, %{state | workers: workers}}

          _ ->
            {:reply, {:error, :cannot_create_worker}, state}
        end
    end
  end

  def handle_call({:remove, slug}, _from, state) do
    case Map.fetch(state.workers, slug) do
      {:ok, %{origin: :cli, busy: false} = item} ->
        File.rm_rf(Path.join([state.root, "workers", slug]))
        {:reply, {:ok, item.live}, %{state | workers: Map.delete(state.workers, slug)}}

      {:ok, %{busy: true}} ->
        {:reply, {:error, :already_deploying}, state}

      {:ok, _local} ->
        {:reply, {:error, :name_owned_by_local_editor}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:begin_upload, slug}, _from, state) do
    cond do
      not valid_slug?(slug) ->
        {:reply, {:error, :invalid_name}, state}

      match?(%{origin: :local}, state.workers[slug]) ->
        {:reply, {:error, :name_owned_by_local_editor}, state}

      match?(%{busy: true}, state.workers[slug]) ->
        {:reply, {:error, :already_deploying}, state}

      Map.has_key?(state.workers, slug) ->
        workers = Map.update!(state.workers, slug, &%{&1 | busy: true})
        {:reply, :ok, %{state | workers: workers}}

      true ->
        path = Path.join([state.root, "workers", slug])

        case File.mkdir(path) do
          :ok ->
            with :ok <-
                   File.write(
                     source_path(state.root, slug),
                     "# Source lives in your local Midgard project.\n"
                   ),
                 :ok <- File.write(Path.join(path, "origin"), "cli\n") do
              workers = Map.put(state.workers, slug, %{live: nil, busy: true, origin: :cli})
              {:reply, :ok, %{state | workers: workers}}
            else
              _ ->
                File.rm_rf(path)
                {:reply, {:error, :cannot_create_worker}, state}
            end

          _ ->
            {:reply, {:error, :cannot_create_worker}, state}
        end
    end
  end

  def handle_call({:begin_deploy, slug, source}, _from, state) do
    with true <- valid_slug?(slug) and is_binary(source) and byte_size(source) in 1..@max_source,
         {:ok, %{origin: :local} = item} <- Map.fetch(state.workers, slug),
         false <- item.busy,
         :ok <- save_source(state.root, slug, source) do
      workers = Map.put(state.workers, slug, %{item | busy: true})
      {:reply, :ok, %{state | workers: workers}}
    else
      :error -> {:reply, {:error, :not_found}, state}
      true -> {:reply, {:error, :already_deploying}, state}
      _ -> {:reply, {:error, :invalid_source}, state}
    end
  end

  def handle_call({:finish_deploy, slug, result}, _from, state) do
    case Map.fetch(state.workers, slug) do
      {:ok, %{busy: true} = item} ->
        old = item.live
        live = if match?({:ok, _}, result), do: elem(result, 1), else: old
        workers = Map.put(state.workers, slug, %{item | busy: false, live: live})
        {:reply, {:ok, old}, %{state | workers: workers}}

      _ ->
        {:reply, {:error, :not_deploying}, state}
    end
  end

  @impl true
  def handle_info(
        {:DOWN, reference, :process, _pid, _reason},
        %{registry_monitor: reference} = state
      ) do
    # The Engine's rest-for-one restart has invalidated every old Isolate ID.
    workers =
      Map.new(state.workers, fn {slug, item} -> {slug, %{item | live: nil, busy: false}} end)

    Process.send_after(self(), :watch_registry, 20)
    {:noreply, %{state | workers: workers, registry_monitor: nil}}
  end

  def handle_info(:watch_registry, state) do
    case Process.whereis(Midgard.Platform.Deployments) do
      nil ->
        Process.send_after(self(), :watch_registry, 20)
        {:noreply, state}

      registry ->
        {:noreply, %{state | registry_monitor: Process.monitor(registry)}}
    end
  end

  defp save_source(root, slug, source) do
    path = source_path(root, slug)
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.write(temporary, source),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      error ->
        File.rm(temporary)
        error
    end
  end

  defp source_path(root, slug), do: Path.join([root, "workers", slug, "source.ex"])

  defp template(slug) do
    """
    defmodule #{Macro.camelize(slug)} do
      use Midgard.Worker

      def handle_request(%Midgard.Request{path: "/hello"}) do
        {200, "Hello from #{slug}!\\n"}
      end

      def handle_request(%Midgard.Request{path: "/hello/" <> name}) do
        if name != "" and not String.contains?(name, "/") do
          {200, "Hello, \#{name}!\\n"}
        else
          {404, "Not found\\n"}
        end
      end

      def handle_request(_request), do: {404, "Not found\\n"}
    end
    """
  end
end
