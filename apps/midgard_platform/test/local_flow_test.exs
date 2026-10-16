if System.get_env("MIDGARD_COMPILER_IMAGE") == "1" do
  defmodule MidgardPlatformLocalFlowTest do
    use ExUnit.Case, async: false
    alias Midgard.Platform.{Publisher, Workspace}

    @tag native: true, timeout: 180_000
    test "a saved Elixir worker gets a live URL; failed edits keep the last deployment" do
      nonce = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      root = Path.join(System.tmp_dir!(), "midgard-flow-test-#{nonce}")

      File.mkdir_p!(root)
      original = Application.get_env(:midgard_platform, :workspace)
      Application.put_env(:midgard_platform, :workspace, root)
      {:ok, platform} = Midgard.Platform.start_link()
      {:ok, workspace} = Workspace.start_link(root: root)

      on_exit(fn ->
        File.rm_rf!(root)

        if original,
          do: Application.put_env(:midgard_platform, :workspace, original),
          else: Application.delete_env(:midgard_platform, :workspace)
      end)

      assert :ok = Workspace.create("hello_local")
      assert {:ok, %{source: source}} = Workspace.read("hello_local")
      assert {:ok, first} = Publisher.deploy("hello_local", source)
      assert first.modules > 300
      get = <<1, 3, 6::16, 0::16, 0, 0::16, "GET", "/hello">>

      assert {:ok, <<2, 200::16, 24::16, "Hello from hello_local!\n">>} =
               Midgard.Platform.call(first.id, get)

      assert {:ok, named_request} =
               Midgard.Protocol.request(%Midgard.Request{method: "GET", path: "/hello/joe"})

      assert {:ok, named_reply} = Midgard.Platform.call(first.id, named_request)
      assert {:ok, {200, "Hello, joe!\n"}} = Midgard.Protocol.decode_response(named_reply)

      updated =
        String.replace(
          source,
          "def handle_request(_request), do: {404, \"Not found\\n\"}",
          "def handle_request(%Midgard.Request{method: \"POST\", path: \"/echo\", body: body}), do: {200, body}\n\n  def handle_request(_request), do: {404, \"Not found\\n\"}"
        )

      assert updated != source
      assert {:ok, second} = Publisher.deploy("hello_local", updated)
      refute first.id == second.id
      assert {:error, :not_deployed} = Midgard.Platform.call(first.id, get)

      assert {:ok, bytes} =
               Midgard.Protocol.request(%Midgard.Request{
                 method: "POST",
                 path: "/echo",
                 body: <<0, 5, 255>>
               })

      assert {:ok, result} = Midgard.Platform.call(second.id, bytes)
      assert {:ok, {200, <<0, 5, 255>>}} = Midgard.Protocol.decode_response(result)

      http =
        Plug.Test.conn(:post, "http://127.0.0.1/run/hello_local/echo", <<0, 5, 255>>)
        |> Plug.Conn.put_req_header("content-type", "application/octet-stream")
        |> Midgard.Platform.Router.call(Midgard.Platform.Router.init([]))

      assert http.status == 200
      assert http.resp_body == <<0, 5, 255>>

      assert [%{slug: "hello_local", invocations: 1, last_invoked_at: timestamp}] =
               Workspace.list()

      assert is_integer(timestamp)

      not_found =
        Plug.Test.conn(:get, "http://127.0.0.1/run/hello_local/missing")
        |> Midgard.Platform.Router.call(Midgard.Platform.Router.init([]))

      assert not_found.status == 404

      oversized =
        Plug.Test.conn(:post, "http://127.0.0.1/run/hello_local/echo", :binary.copy("x", 32_769))
        |> Midgard.Platform.Router.call(Midgard.Platform.Router.init([]))

      assert oversized.status == 413
      assert [%{invocations: 2}] = Workspace.list()

      assert {:error, message} = Publisher.deploy("hello_local", updated <> "\ninvalid elixir !")
      assert message =~ "compiler failed"
      assert {:ok, %{record: %{live: %{id: id}, busy: false}}} = Workspace.read("hello_local")
      assert id == second.id
      assert {:ok, _reply} = Midgard.Platform.call(id, get)

      # The registry is restarted after native Port death. No URL may claim
      # a stale Isolate handle is live, even though the draft stays on disk.
      ref = Process.monitor(Process.whereis(Midgard.Platform.Deployments))
      Port.close(:sys.get_state(Midgard.Platform.NativeEngine).port)
      assert_receive {:DOWN, ^ref, :process, _, _}, 5_000

      assert Enum.any?(1..100, fn _ ->
               case Workspace.read("hello_local") do
                 {:ok, %{record: %{live: nil}}} ->
                   true

                 _ ->
                   Process.sleep(5)
                   false
               end
             end)

      assert [%{slug: "hello_local", live: nil, invocations: 2}] = Workspace.list()
      Supervisor.stop(platform)
      GenServer.stop(workspace)
    end
  end
end
