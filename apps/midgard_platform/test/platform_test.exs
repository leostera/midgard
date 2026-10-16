defmodule MidgardPlatformTest do
  use ExUnit.Case, async: false
  alias Midgard.Platform
  alias Midgard.Platform.Shipment

  test "shipment hashes and exact file inventory are checked before admission" do
    {directory, beam_path} = echo_shipment()
    on_exit(fn -> File.rm_rf!(directory) end)

    assert {:ok, %Shipment{module: "platform_echo", function: "handle", modules: [beam]}} =
             Shipment.read(directory)

    assert byte_size(beam) > 12
    File.write!(beam_path, <<0>> <> binary_part(beam, 1, byte_size(beam) - 1))
    assert {:error, message} = Shipment.read(directory)
    assert message =~ "checksum"
    File.write!(beam_path, beam)
    File.write!(Path.join(directory, "modules/undeclared.beam"), beam)
    assert {:error, "shipment contains missing or undeclared files"} = Shipment.read(directory)
  end

  test "a symlinked BEAM file is not accepted as local shipment input" do
    {directory, beam_path} = echo_shipment()
    on_exit(fn -> File.rm_rf!(directory) end)
    original = File.read!(beam_path)
    copy = Path.join(directory, "original.beam")
    File.write!(copy, original)
    File.rm!(beam_path)
    File.ln_s!(copy, beam_path)
    assert {:error, "shipment contains missing or undeclared files"} = Shipment.read(directory)
    File.rm!(copy)

    assert {:error, "shipment file is missing, oversized, or a symlink"} =
             Shipment.read(directory)
  end

  @tag :native
  test "one Engine hosts distinct deployments with independent Isolate lifecycles" do
    {directory, _beam_path} = echo_shipment()
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, platform} = Platform.start_link()

    assert {:ok, digest} = Platform.deploy("alpha", directory)
    assert is_binary(digest)
    assert {:ok, ^digest} = Platform.deploy("beta", directory)
    assert {:error, :already_deployed} = Platform.deploy("alpha", directory)
    assert {:ok, <<0, 10, 255>>} = Platform.call("alpha", <<0, 10, 255>>)
    assert {:ok, <<2, 3>>} = Platform.call("beta", <<2, 3>>)
    assert :ok = Platform.stop("alpha")
    assert {:error, :not_deployed} = Platform.call("alpha", <<9>>)
    assert {:ok, <<9>>} = Platform.call("beta", <<9>>)
    assert :ok = Platform.stop("beta")
    Supervisor.stop(platform)
  end

  @tag :native
  test "a native Port failure loses deployments and requires explicit redeploy" do
    {directory, _beam_path} = echo_shipment()
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, platform} = Platform.start_link()
    assert {:ok, _} = Platform.deploy("tenant", directory)
    old_registry = Process.whereis(Midgard.Platform.Deployments)
    monitor = Process.monitor(old_registry)
    port = :sys.get_state(Midgard.Platform.NativeEngine).port
    Port.close(port)
    assert_receive {:DOWN, ^monitor, :process, ^old_registry, _}, 5_000

    assert Enum.any?(1..100, fn _ ->
             if Process.whereis(Midgard.Platform.Deployments) not in [nil, old_registry] do
               true
             else
               Process.sleep(5)
               false
             end
           end)

    assert {:error, :not_deployed} = Platform.call("tenant", <<1>>)
    assert {:ok, _} = Platform.deploy("tenant", directory)
    assert {:ok, <<1>>} = Platform.call("tenant", <<1>>)
    assert :ok = Platform.stop("tenant")
    Supervisor.stop(platform)
  end

  @tag :native
  test "a valid but incomplete shipment refuses atomic admission and receives no traffic" do
    {directory, _beam_path} = echo_shipment("platform_helper:help(Bytes)")
    on_exit(fn -> File.rm_rf!(directory) end)
    assert {:ok, %Shipment{}} = Shipment.read(directory)
    {:ok, platform} = Platform.start_link()
    assert {:error, %Libbeam.Error{message: message}} = Platform.deploy("incomplete", directory)
    assert message =~ "unresolved import"
    assert {:error, :not_deployed} = Platform.call("incomplete", <<1>>)
    Supervisor.stop(platform)
  end

  if System.get_env("MIDGARD_COMPILER_IMAGE") == "1" do
    @tag native: true, timeout: 180_000
    test "Elixir source compiles in a restricted container and its exact closure runs in an Isolate" do
      directory =
        Path.join(System.tmp_dir!(), "midgard-compiler-e2e-#{System.unique_integer([:positive])}")

      File.mkdir_p!(directory)
      on_exit(fn -> File.rm_rf!(directory) end)
      artifact = Path.join(directory, "browser_worker.midgard")

      source = """
      defmodule BrowserWorker do
        use Midgard.Worker
        def handle_request(%Midgard.Request{path: "/hello"}), do: {200, "Hello, world!\\n"}
        def handle_request(_), do: {404, "Not found\\n"}
      end
      """

      assert {:ok, %{modules: count}} =
               Midgard.Platform.Compiler.compile("browser_worker", source, artifact)

      assert count > 300
      assert {:ok, %Shipment{}} = Shipment.read(artifact)
      {:ok, platform} = Platform.start_link()
      assert {:ok, _} = Platform.deploy("browser_worker", artifact, defer_denied_nif: true)
      get = <<1, 3, 6::16, 0::16, 0, 0::16, "GET", "/hello">>

      assert {:ok, <<2, 200::16, 14::16, "Hello, world!\n">>} =
               Platform.call("browser_worker", get)

      assert :ok = Platform.stop("browser_worker")
      Supervisor.stop(platform)
    end

    @tag native: true, timeout: 180_000
    test "browser source can run a compile-time effect only inside the container" do
      root =
        Path.join(
          System.tmp_dir!(),
          "midgard-compile-sandbox-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      marker = "/tmp/midgard-host-marker-#{System.unique_integer([:positive])}"
      refute File.exists?(marker)

      source = """
      defmodule IsolatedWorker do
        @compile_result File.write!(#{inspect(marker)}, "inside container")
        use Midgard.Worker
        def handle_request(_), do: {200, "ok"}
      end
      """

      assert {:ok, _} =
               Midgard.Platform.Compiler.compile(
                 "isolated_worker",
                 source,
                 Path.join(root, "out.midgard")
               )

      refute File.exists?(marker)
    end

    @tag native: true, timeout: 180_000
    test "compiler output is bounded and a noisy build never publishes an artifact" do
      root =
        Path.join(
          System.tmp_dir!(),
          "midgard-compile-noise-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      artifact = Path.join(root, "noisy.midgard")

      source = """
      defmodule Noisy do
        IO.write(String.duplicate("x", 80_000))
        use Midgard.Worker
        def handle_request(_), do: {200, "ok"}
      end
      """

      assert {:error, "compiler output exceeded 64 KiB"} =
               Midgard.Platform.Compiler.compile("noisy", source, artifact)

      refute File.exists?(artifact)
    end
  end

  defp echo_shipment(body \\ "Bytes") do
    directory =
      Path.join(System.tmp_dir!(), "midgard-platform-#{System.unique_integer([:positive])}")

    module_dir = Path.join(directory, "modules")
    File.mkdir_p!(module_dir)
    source_dir = Path.join(directory, "scratch")
    File.mkdir_p!(source_dir)
    source = Path.join(source_dir, "platform_echo.erl")

    File.write!(
      source,
      "-module(platform_echo). -export([handle/1]). handle(Bytes) -> #{body}.\n"
    )

    {:ok, :platform_echo} =
      :compile.file(String.to_charlist(source), [
        :deterministic,
        {:outdir, String.to_charlist(module_dir)}
      ])

    File.rm_rf!(source_dir)
    path = Path.join(module_dir, "platform_echo.beam")
    bytes = File.read!(path)

    manifest = %{
      "application" => "platform_echo",
      "compiler" => %{
        "otp_release" => to_string(:erlang.system_info(:otp_release)),
        "elixir_version" => System.version()
      },
      "dependencies" => [],
      "entrypoint" => %{
        "arity" => 1,
        "function" => "handle",
        "module" => "platform_echo",
        "protocol" => "raw.bytes.v1"
      },
      "format" => "midgard.beam",
      "format_version" => 1,
      "modules" => [
        %{
          "name" => "platform_echo",
          "owner" => "platform_echo",
          "path" => "modules/platform_echo.beam",
          "sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
          "size" => byte_size(bytes)
        }
      ],
      "required_capabilities" => [],
      "target" => %{
        "runtime" => "libbeam",
        "contract" => "provisional-isolate-v1",
        "execution" => "not_verified"
      }
    }

    File.write!(Path.join(directory, "manifest.json"), :json.encode(manifest))
    {directory, path}
  end
end
