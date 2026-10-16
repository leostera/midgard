if System.get_env("MIDGARD_COMPILER_IMAGE") == "1" do
  defmodule MidgardPlatformLocalFlowTest do
    use ExUnit.Case, async: false
    alias Midgard.Platform.{Publisher, Workspace}

    @tag native: true, timeout: 180_000
    test "a saved Elixir worker gets a live URL; failed edits keep the last deployment" do
      root =
        Path.join(System.tmp_dir!(), "midgard-flow-test-#{System.unique_integer([:positive])}")

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

      assert {:error, message} = Publisher.deploy("hello_local", source <> "\ninvalid elixir !")
      assert message =~ "compiler failed"
      assert {:ok, %{record: %{live: %{id: id}, busy: false}}} = Workspace.read("hello_local")
      assert id == first.id
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

      Supervisor.stop(platform)
      GenServer.stop(workspace)
    end
  end
end
