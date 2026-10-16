defmodule Midgard.Platform.Workspace do
  @moduledoc """
  Trusted-local source workspace. The only persistent files are bounded source
  drafts and immutable deployment artifacts; running handles never survive an
  Engine restart and therefore are deliberately not restored from disk.
  """
  use GenServer
  @max_workers 100
  @max_source 65_536
  @slug ~r/\A[a-z][a-z0-9_]{0,39}\z/

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)
  def list, do: GenServer.call(__MODULE__, :list)
  def read(slug), do: GenServer.call(__MODULE__, {:read, slug})
  def create(slug), do: GenServer.call(__MODULE__, {:create, slug})
  def begin_deploy(slug, source), do: GenServer.call(__MODULE__, {:begin_deploy, slug, source})
  def finish_deploy(slug, result), do: GenServer.call(__MODULE__, {:finish_deploy, slug, result})

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
      |> Map.new(&{&1, %{live: nil, busy: false}})

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
        %{slug: slug, live: item.live, busy: item.busy}
      end)
      |> Enum.sort_by(& &1.slug)

    {:reply, rows, state}
  end

  def handle_call({:read, slug}, _from, state) do
    if valid_slug?(slug) and Map.has_key?(state.workers, slug) do
      case File.read(source_path(state.root, slug)) do
        {:ok, bytes} -> {:reply, {:ok, %{source: bytes, record: state.workers[slug]}}, state}
        _ -> {:reply, {:error, :source_unavailable}, state}
      end
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

      map_size(state.workers) >= @max_workers ->
        {:reply, {:error, :worker_limit}, state}

      true ->
        path = Path.join([state.root, "workers", slug])

        case File.mkdir(path) do
          :ok ->
            File.write!(source_path(state.root, slug), template(slug))
            workers = Map.put(state.workers, slug, %{live: nil, busy: false})
            {:reply, :ok, %{state | workers: workers}}

          _ ->
            {:reply, {:error, :cannot_create_worker}, state}
        end
    end
  end

  def handle_call({:begin_deploy, slug, source}, _from, state) do
    with true <- valid_slug?(slug) and is_binary(source) and byte_size(source) in 1..@max_source,
         {:ok, item} <- Map.fetch(state.workers, slug),
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

      def handle_request(_request), do: {404, "Not found\\n"}
    end
    """
  end
end
