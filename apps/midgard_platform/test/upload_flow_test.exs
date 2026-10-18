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
      cli_source = Path.join(root, "midgard_cli")
      mix_home = Path.join(root, "mix-home")
      hex_home = Path.join(root, "hex-home")
      mix_env = [{"MIX_HOME", mix_home}, {"HEX_HOME", hex_home}]
      File.mkdir_p!(root)
      File.cp_r!(Path.join(checkout, "apps/midgard_cli"), cli_source)
      mix!("archive.build", [], cli_source, mix_env)
      archive = Path.join(cli_source, "midgard_cli-0.1.0.ez")
      mix!("archive.install", [archive, "--force"], checkout, mix_env)

      mix!(
        "midgard.new",
        ["upload_sample", "--path", project, "--midgard-root", checkout],
        checkout,
        mix_env
      )

      original = Application.get_env(:midgard_platform, :workspace)
      original_container = System.get_env("MIDGARD_CONTAINER_HTTP")
      original_key = System.get_env("MIDGARD_INTERNAL_UPLOAD_KEY")
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

        if original_container,
          do: System.put_env("MIDGARD_CONTAINER_HTTP", original_container),
          else: System.delete_env("MIDGARD_CONTAINER_HTTP")

        if original_key,
          do: System.put_env("MIDGARD_INTERNAL_UPLOAD_KEY", original_key),
          else: System.delete_env("MIDGARD_INTERNAL_UPLOAD_KEY")

        if original,
          do: Application.put_env(:midgard_platform, :workspace, original),
          else: Application.delete_env(:midgard_platform, :workspace)
      end)

      mix!("deps.get", [], project, mix_env)
      mix!("test", [], project, mix_env)

      output =
        mix!("midgard.deploy", ["--endpoint", "http://127.0.0.1:#{port}"], project, mix_env)

      assert output =~ "Deployed upload_sample"
      assert [%{slug: "upload_sample", live: %{modules: modules}}] = Workspace.list()
      assert modules > 300

      conn =
        Plug.Test.conn(:get, "http://127.0.0.1/run/upload_sample/hello")
        |> Midgard.Platform.Router.call(Midgard.Platform.Router.init([]))

      assert conn.status == 200,
             "worker invocation returned HTTP #{conn.status}: #{conn.resp_body}"

      assert conn.resp_body == "Hello from UploadSample!\n"

      index =
        Plug.Test.conn(:get, "http://127.0.0.1/")
        |> Midgard.Platform.Router.call(Midgard.Platform.Router.init([]))

      assert index.resp_body =~ "upload_sample"
      assert index.resp_body =~ "Deployed"

      shipment = Path.join(project, "upload_sample.midgard")
      {:ok, packed} = Packer.ShipmentUpload.read_directory(shipment)
      gateway = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
      public_slug = "upload_sample_0123456789abcdef"
      System.put_env("MIDGARD_CONTAINER_HTTP", "1")
      System.put_env("MIDGARD_INTERNAL_UPLOAD_KEY", gateway)

      unauthorized =
        Plug.Test.conn(
          :post,
          "http://127.0.0.1/api/deployments/upload_sample",
          Packer.ShipmentUpload.encode(packed)
        )
        |> Plug.Conn.put_req_header("content-type", Packer.ShipmentUpload.content_type())
        |> Midgard.Platform.Router.call(Midgard.Platform.Router.init([]))

      assert unauthorized.status == 401

      public =
        Plug.Test.conn(
          :post,
          "http://127.0.0.1/api/deployments/upload_sample",
          Packer.ShipmentUpload.encode(packed)
        )
        |> Plug.Conn.put_req_header("content-type", Packer.ShipmentUpload.content_type())
        |> Plug.Conn.put_req_header("x-midgard-public-route", public_slug)
        |> Plug.Conn.put_req_header("x-midgard-internal-upload", "Bearer " <> gateway)
        |> Midgard.Platform.Router.call(Midgard.Platform.Router.init([]))

      assert public.status == 201
      assert %{"slug" => ^public_slug, "path" => "/run/" <> _} = :json.decode(public.resp_body)

      assert Plug.Test.conn(:get, "http://127.0.0.1/run/#{public_slug}/hello")
             |> Midgard.Platform.Router.call(Midgard.Platform.Router.init([]))
             |> Map.get(:resp_body) == "Hello from UploadSample!\n"

      System.delete_env("MIDGARD_CONTAINER_HTTP")
      System.delete_env("MIDGARD_INTERNAL_UPLOAD_KEY")

      beam_path = Path.join([shipment, "modules", "Elixir.UploadSample.beam"])
      original_beam = File.read!(beam_path)
      <<_first, tail::binary>> = original_beam
      File.write!(beam_path, <<0, tail::binary>>)

      {error, code} =
        System.cmd(
          "mix",
          ["midgard.deploy", "--artifact", shipment, "--endpoint", "http://127.0.0.1:#{port}"],
          cd: project,
          env: mix_env,
          stderr_to_stdout: true
        )

      refute code == 0
      assert error =~ "checksum mismatch"

      assert %{live: %{modules: ^modules}, busy: false} =
               Enum.find(Workspace.list(), &(&1.slug == "upload_sample"))

      assert Plug.Test.conn(:get, "http://127.0.0.1/run/upload_sample/hello")
             |> Midgard.Platform.Router.call(Midgard.Platform.Router.init([]))
             |> Map.get(:status) == 200

      GenServer.stop(registry)
      {:ok, recovered} = Workspace.start_link(root: workspace)
      Process.unlink(recovered)

      assert Enum.sort(Enum.map(Workspace.list(), &{&1.slug, &1.live})) ==
               [{"upload_sample", nil}, {public_slug, nil}]

      assert Plug.Test.conn(:get, "http://127.0.0.1/run/upload_sample/hello")
             |> Midgard.Platform.Router.call(Midgard.Platform.Router.init([]))
             |> Map.get(:status) == 404
    end

    defp mix!(task, args, directory, env) do
      {output, status} =
        System.cmd("mix", [task | args], cd: directory, env: env, stderr_to_stdout: true)

      if status != 0, do: flunk("mix #{task} failed with status #{status}:\n#{output}")
      output
    end
  end
end
