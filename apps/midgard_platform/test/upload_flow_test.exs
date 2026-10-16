if System.get_env("MIDGARD_NATIVE_UPLOAD") == "1" do
  defmodule MidgardPlatformUploadFlowTest do
    use ExUnit.Case, async: false
    alias Midgard.Platform.Workspace

    @tag timeout: 180_000
    test "generated Mix project deploys over HTTP, appears in inventory, and runs in an Isolate" do
      nonce = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      root = Path.join(System.tmp_dir!(), "midgard-upload-#{nonce}")
      project = Path.join(root, "upload_sample")
      workspace = Path.join(root, "workspace")
      checkout = Path.expand("../../..", __DIR__)
      File.mkdir_p!(root)
      assert {:ok, ^project} = Midgard.CLI.Generator.generate("upload_sample", project, checkout)

      original = Application.get_env(:midgard_platform, :workspace)
      Application.put_env(:midgard_platform, :workspace, workspace)
      {:ok, platform} = Midgard.Platform.start_link()
      {:ok, registry} = Workspace.start_link(root: workspace)
      {:ok, socket} = :gen_tcp.listen(0, [:binary, {:ip, {127, 0, 0, 1}}])
      {:ok, {_, port}} = :inet.sockname(socket)
      :ok = :gen_tcp.close(socket)

      {:ok, web} =
        Bandit.start_link(
          plug: Midgard.Platform.Router,
          port: port,
          ip: {127, 0, 0, 1},
          startup_log: false
        )

      # ExUnit runs on_exit in another process; preserve the three linked
      # services until that process can stop them in dependency order.
      Process.unlink(platform)
      Process.unlink(registry)
      Process.unlink(web)

      on_exit(fn ->
        if Process.alive?(web), do: Supervisor.stop(web)
        if Process.alive?(platform), do: Supervisor.stop(platform)
        if current = Process.whereis(Workspace), do: GenServer.stop(current)
        File.rm_rf!(root)

        if original,
          do: Application.put_env(:midgard_platform, :workspace, original),
          else: Application.delete_env(:midgard_platform, :workspace)
      end)

      {_, 0} = System.cmd("mix", ["deps.get"], cd: project, stderr_to_stdout: true)

      {output, code} =
        System.cmd("mix", ["midgard.deploy", "--endpoint", "http://127.0.0.1:#{port}"],
          cd: project,
          stderr_to_stdout: true
        )

      assert code == 0, output
      assert output =~ "Deployed upload_sample"
      assert [%{slug: "upload_sample", live: %{modules: modules}}] = Workspace.list()
      assert modules > 300

      conn =
        Plug.Test.conn(:get, "http://127.0.0.1/run/upload_sample/hello")
        |> Midgard.Platform.Router.call(Midgard.Platform.Router.init([]))

      assert conn.status == 200
      assert conn.resp_body == "Hello from UploadSample!\n"

      index =
        Plug.Test.conn(:get, "http://127.0.0.1/")
        |> Midgard.Platform.Router.call(Midgard.Platform.Router.init([]))

      assert index.resp_body =~ "upload_sample"
      assert index.resp_body =~ "Deployed"

      shipment = Path.join(project, "upload_sample.midgard")
      beam_path = Path.join([shipment, "modules", "Elixir.UploadSample.beam"])
      original_beam = File.read!(beam_path)
      <<_first, tail::binary>> = original_beam
      File.write!(beam_path, <<0, tail::binary>>)

      {error, code} =
        System.cmd(
          "mix",
          ["midgard.deploy", "--artifact", shipment, "--endpoint", "http://127.0.0.1:#{port}"],
          cd: project,
          stderr_to_stdout: true
        )

      refute code == 0
      assert error =~ "checksum mismatch"
      assert [%{live: %{modules: ^modules}, busy: false}] = Workspace.list()

      assert Plug.Test.conn(:get, "http://127.0.0.1/run/upload_sample/hello")
             |> Midgard.Platform.Router.call(Midgard.Platform.Router.init([]))
             |> Map.get(:status) == 200

      GenServer.stop(registry)
      {:ok, recovered} = Workspace.start_link(root: workspace)
      Process.unlink(recovered)
      assert [%{slug: "upload_sample", live: nil}] = Workspace.list()
      assert Plug.Test.conn(:get, "http://127.0.0.1/run/upload_sample/hello")
             |> Midgard.Platform.Router.call(Midgard.Platform.Router.init([]))
             |> Map.get(:status) == 404
    end
  end
end
