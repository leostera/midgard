defmodule LibbeamPortTest do
  use ExUnit.Case, async: false
  alias Libbeam.{Engine, Isolate, PortProtocol}

  test "packet parser rejects malformed messages and oversize inputs" do
    assert {:error, _} = PortProtocol.decode(<<1, 1::64, 1, 1::16, 4::16, "bad">>)
    assert {:error, _} = PortProtocol.decode(<<2, 1::64, 0>>)
    assert {:error, _} = PortProtocol.encode(1, :call, :binary.copy(<<0>>, 32 * 1024 * 1024))
    assert {:error, _} = PortProtocol.load_payload(1, [], [])

    assert {:error, _} =
             PortProtocol.call_payload(1, "module", "handle", :binary.copy(<<0>>, 65_537))
  end

  @tag :native
  test "real libbeam Port owns multiple independently loaded Isolates and reclaims them" do
    {directory, beam} = echo_module()
    on_exit(fn -> File.rm_rf!(directory) end)

    {:ok, engine} = Engine.start_link()
    {:ok, first} = Engine.create_isolate(engine)
    {:ok, second} = Engine.create_isolate(engine)
    assert first.id != second.id
    assert {:error, %Libbeam.Error{}} = Isolate.load_modules(first, [<<0, 1>>])
    assert :ok = Isolate.load_modules(first, [beam])
    assert :ok = Isolate.load_modules(second, [beam])

    calls =
      for {isolate, bytes} <- [{first, <<0, 10, 255>>}, {second, <<255, 0, 1>>}] do
        Task.async(fn -> Isolate.call(isolate, "port_echo", "handle", bytes) end)
      end

    assert Enum.map(calls, &Task.await(&1, 15_000)) ==
             [{:ok, <<0, 10, 255>>}, {:ok, <<255, 0, 1>>}]

    assert {:ok, <<5>>} = Isolate.call(first, "port_echo", "handle", <<5>>)
    assert :ok = Isolate.stop(first)
    assert {:error, %Libbeam.Error{}} = Isolate.call(first, "port_echo", "handle", <<0>>)
    assert {:ok, <<9>>} = Isolate.call(second, "port_echo", "handle", <<9>>)
    assert :ok = Isolate.stop(second)
    assert :ok = Engine.shutdown(engine)
  end

  @tag :native
  test "a Port exit fails an outstanding call instead of hanging its caller" do
    {directory, beam} = echo_module()
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, supervisor} = Libbeam.Supervisor.start_link()
    {:ok, engine} = Libbeam.Supervisor.start_engine(supervisor)
    {:ok, isolate} = Engine.create_isolate(engine, invocation_work_limit: 10_000_000_000)
    :ok = Isolate.load_modules(isolate, [beam])
    waiting = Task.async(fn -> Isolate.call(isolate, "port_echo", "handle", <<255, 254>>) end)

    assert Enum.any?(1..100, fn _ ->
             if map_size(:sys.get_state(engine).pending) > 0 do
               true
             else
               Process.sleep(5)
               false
             end
           end)

    Port.close(:sys.get_state(engine).port)
    assert {:error, %Libbeam.Error{code: :closed}} = Task.await(waiting, 5_000)
    :ok = DynamicSupervisor.stop(supervisor)
  end

  @tag :native
  test "a Port exit invalidates old handles while the supervisor restarts its Engine" do
    {:ok, supervisor} = Libbeam.Supervisor.start_link()
    {:ok, engine} = Libbeam.Supervisor.start_engine(supervisor)
    {:ok, isolate} = Engine.create_isolate(engine)
    monitor = Process.monitor(engine)

    Port.close(:sys.get_state(engine).port)
    assert_receive {:DOWN, ^monitor, :process, ^engine, _reason}, 5_000

    assert {:error, %Libbeam.Error{code: :closed}} =
             Isolate.call(isolate, "port_echo", "handle", <<0>>)

    assert %{active: 1} = DynamicSupervisor.count_children(supervisor)
    :ok = DynamicSupervisor.stop(supervisor)
  end

  test "an unavailable executable refuses startup without starting an Isolate" do
    Process.flag(:trap_exit, true)

    assert {:error, :native_host_executable_missing} =
             Engine.start_link(executable: "/definitely/missing/libbeam_host")

    Process.flag(:trap_exit, false)
  end

  if System.get_env("LIBBEAM_HELLO_BUNDLE") do
    @tag native: true, timeout: 180_000
    test "unchanged HelloWorker closure executes via the Port at default limits" do
      bundle = File.read!(System.fetch_env!("LIBBEAM_HELLO_BUNDLE"))

      <<"LBAPP001", manifest_size::32, _manifest::binary-size(manifest_size), count::32,
        records::binary>> = bundle

      {beams, <<>>} =
        Enum.map_reduce(1..count, records, fn _, <<name_size::16, rest::binary>> ->
          <<_name::binary-size(^name_size), size::32, beam::binary-size(size), tail::binary>> =
            rest

          {beam, tail}
        end)

      {:ok, engine} = Engine.start_link()
      {:ok, isolate} = Engine.create_isolate(engine)
      assert :ok = Isolate.load_modules(isolate, beams, defer_denied_nif: true)

      get = <<1, 3, 6::16, 0::16, 0, 0::16, "GET", "/hello">>

      assert {:ok, <<2, 200::16, 14::16, "Hello, world!\n">>} =
               Isolate.call(isolate, "Elixir.HelloWorker", "__midgard_call__", get)

      body = ~s({"name":"Leo"})
      post = <<1, 4, 5::16, 0::16, 0, byte_size(body)::16, "POST", "/json", body::binary>>
      expected = ~s({"greeting":"Hello, Leo!\\n"})
      length = byte_size(expected)

      assert {:ok, <<2, 200::16, ^length::16, ^expected::binary>>} =
               Isolate.call(isolate, "Elixir.HelloWorker", "__midgard_call__", post)

      assert :ok = Isolate.stop(isolate)
      assert :ok = Engine.shutdown(engine)
    end
  end

  defp echo_module do
    directory = Path.join(System.tmp_dir!(), "libbeam-port-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    source = Path.join(directory, "port_echo.erl")

    File.write!(
      source,
      "-module(port_echo). -export([handle/1]). handle(<<255,254>>) -> spin(); handle(Bytes) -> Bytes. spin() -> spin().\n"
    )

    {:ok, :port_echo} =
      :compile.file(String.to_charlist(source), [
        :deterministic,
        {:outdir, String.to_charlist(directory)}
      ])

    {directory, File.read!(Path.join(directory, "port_echo.beam"))}
  end
end
