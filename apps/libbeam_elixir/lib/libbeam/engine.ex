defmodule Libbeam.Engine do
  @moduledoc """
  Owns one native Port and one libbeam Engine. Calls are correlated and replied
  to from Port messages; guest execution never blocks this GenServer.

  A host exit invalidates all Isolate handles and fails outstanding requests.
  The executable is supplied explicitly for development; native distribution
  and ABI version pinning must precede publishing this package.
  """
  use GenServer
  alias Libbeam.{Error, Isolate, PortProtocol}

  @handshake <<1, 0::64, 0>>
  @handshake_reply <<1, 0::64, 0, "libbeam-port-v1">>

  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))
  end

  def create_isolate(engine, options \\ []) do
    memory = Keyword.get(options, :memory_limit_bytes, 0)
    work = Keyword.get(options, :invocation_work_limit, 0)

    if valid_uint64?(memory) and valid_uint64?(work) do
      request(engine, :create, <<memory::64, work::64>>, :create)
    else
      {:error, Error.exception(code: :invalid_argument, message: "invalid Isolate limits")}
    end
  end

  def load_modules(%Isolate{engine: engine, id: id}, beams, options \\ []) do
    case PortProtocol.load_payload(id, beams, options) do
      {:ok, bytes} -> request(engine, :load, bytes, :unit)
      {:error, message} -> {:error, Error.exception(code: :invalid_argument, message: message)}
    end
  end

  def call(%Isolate{engine: engine, id: id}, module, function, input) do
    case PortProtocol.call_payload(id, module, function, input) do
      {:ok, bytes} -> request(engine, :call, bytes, :bytes)
      {:error, message} -> {:error, Error.exception(code: :invalid_argument, message: message)}
    end
  end

  def stop_isolate(%Isolate{engine: engine, id: id}) do
    request(engine, :stop, <<id::64>>, :unit)
  end

  def shutdown(engine) do
    request(engine, :shutdown, <<>>, :shutdown)
  end

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    executable = Keyword.get(options, :executable, default_executable())

    if is_binary(executable) and File.regular?(executable) do
      try do
        port =
          Port.open(
            {:spawn_executable, String.to_charlist(executable)},
            [:binary, {:packet, 4}, :exit_status]
          )

        if Port.command(port, @handshake) do
          receive do
            {^port, {:data, @handshake_reply}} ->
              {:ok, %{port: port, pending: %{}, next_id: 1}}

            {^port, {:data, _}} ->
              Port.close(port)
              {:stop, :incompatible_native_host}

            {^port, {:exit_status, status}} ->
              {:stop, {:native_host_exited, status}}
          after
            5_000 ->
              Port.close(port)
              {:stop, :native_host_handshake_timeout}
          end
        else
          Port.close(port)
          {:stop, :native_host_unavailable}
        end
      rescue
        error -> {:stop, {:native_host_unavailable, Exception.message(error)}}
      end
    else
      {:stop, :native_host_executable_missing}
    end
  end

  @impl true
  def handle_call({:request, operation, payload, kind}, from, state) do
    id = state.next_id

    case PortProtocol.encode(id, operation, payload) do
      {:ok, bytes} ->
        if Port.command(state.port, bytes) do
          {:noreply,
           %{state | next_id: id + 1, pending: Map.put(state.pending, id, {from, kind})}}
        else
          {:stop, :native_host_unavailable, {:error, closed()}, state}
        end

      {:error, reason} ->
        {:reply, {:error, Error.exception(code: :invalid_argument, message: reason)}, state}
    end
  end

  @impl true
  def handle_info({port, {:data, frame}}, %{port: port} = state) do
    case PortProtocol.decode(frame) do
      {:ok, id, result} ->
        case Map.pop(state.pending, id) do
          {nil, _} ->
            {:stop, :unexpected_native_response, state}

          {{from, kind}, pending} ->
            GenServer.reply(from, reply(kind, result, self()))

            if kind == :shutdown and match?({:ok, _}, result),
              do: {:stop, :normal, %{state | pending: pending}},
              else: {:noreply, %{state | pending: pending}}
        end

      {:error, _} ->
        {:stop, :invalid_native_response, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state),
    do: {:stop, {:native_host_exited, status}, state}

  def handle_info({:EXIT, port, reason}, %{port: port} = state),
    do: {:stop, {:native_host_exited, reason}, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.pending, fn {_id, {from, _kind}} ->
      GenServer.reply(from, {:error, closed()})
    end)

    if Port.info(state.port), do: Port.close(state.port)
    :ok
  end

  defp reply(_, {:error, error}, _engine), do: {:error, error}
  defp reply(:create, {:ok, <<id::64>>}, engine), do: {:ok, %Isolate{engine: engine, id: id}}
  defp reply(:bytes, {:ok, bytes}, _engine), do: {:ok, bytes}
  defp reply(kind, {:ok, <<>>}, _engine) when kind in [:load, :unit, :shutdown], do: :ok
  defp reply(_, {:ok, _}, _engine), do: {:error, closed()}

  defp request(engine, operation, payload, kind) do
    GenServer.call(engine, {:request, operation, payload, kind}, :infinity)
  catch
    :exit, _ -> {:error, closed()}
  end

  defp valid_uint64?(n), do: is_integer(n) and n >= 0 and n <= 18_446_744_073_709_551_615

  defp closed,
    do: Error.exception(code: :closed, message: "native host closed; Isolate handles are invalid")

  defp default_executable,
    do: Application.app_dir(:libbeam_elixir, "priv/libbeam_host")
end
