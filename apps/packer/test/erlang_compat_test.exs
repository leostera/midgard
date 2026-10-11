defmodule Packer.ErlangCompatTest do
  use ExUnit.Case, async: false

  setup do
    root =
      Path.join(System.tmp_dir!(), "erlang-beam-fixture-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "conventional Erlang module passes structural inspection without execution proof", %{
    root: root
  } do
    beam = compile_erlang!(root, "safe_worker", "handle(B) when is_binary(B) -> B.")
    output = Path.join(root, "safe.midgard")
    record = %{name: "safe_worker", owner: "fixture", bytes: beam}

    assert {:ok, ^output} =
             Packer.Artifact.build(output, "fixture", "safe_worker", [record], [],
               function: "handle",
               protocol: "raw.bytes.v1"
             )

    assert {:ok, manifest} = Packer.Verifier.verify(output)
    assert manifest["entrypoint"]["module"] == "safe_worker"
    assert {:ok, report} = Packer.Profile.report(output)
    assert report["execution"] == "not_verified"
    assert report["known_unsupported_current_core"] == []
  end

  test "Erlang host-authority import and on_load are rejected", %{root: root} do
    for {suffix, body} <- [
          {"file", "handle(Path) -> file:read_file(Path)."},
          {"nif", "handle(Path) -> erlang:load_nif(Path, 0)."}
        ] do
      name = "unsafe_#{suffix}"
      beam = compile_erlang!(root, name, body)
      path = Path.join(root, "#{name}.midgard")

      assert {:error, reason} =
               Packer.Artifact.build(
                 path,
                 "fixture",
                 name,
                 [%{name: name, owner: "fixture", bytes: beam}],
                 [],
                 function: "handle",
                 protocol: "raw.bytes.v1"
               )

      assert reason =~ "host-authority import"
      refute File.exists?(path)
    end

    source =
      "-module(on_load_worker).\n-on_load(init/0).\n-export([handle/1]).\ninit() -> ok.\nhandle(B) -> B.\n"

    beam = compile_source!(root, "on_load_worker", source)
    output = Path.join(root, "on_load.midgard")

    assert {:error, reason} =
             Packer.Artifact.build(
               output,
               "fixture",
               "on_load_worker",
               [%{name: "on_load_worker", owner: "fixture", bytes: beam}],
               [],
               function: "handle",
               protocol: "raw.bytes.v1"
             )

    assert reason =~ "on_load"
  end

  test "missing Erlang compilation cannot be silently omitted", %{root: root} do
    File.mkdir_p!(Path.join(root, "src"))
    File.mkdir_p!(Path.join(root, "ebin"))

    File.write!(
      Path.join(root, "src/forgotten.erl"),
      "-module(forgotten).\n-export([go/1]).\ngo(B) -> B.\n"
    )

    assert {:error, reason} = Packer.BeamFiles.collect(root, Path.join(root, "ebin"))
    assert reason =~ "compiled Erlang"

    File.write!(Path.join(root, "ebin/unrelated.beam"), "BEAM")
    assert {:error, reason} = Packer.BeamFiles.collect(root, Path.join(root, "ebin"))
    assert reason =~ "no matching compiled BEAM"
  end

  test "native source and unpackaged resources are rejected before BEAM collection", %{root: root} do
    beam = compile_erlang!(root, "native_probe", "handle(B) -> B.")
    src = Path.join(root, "src")
    ebin = Path.join(root, "ebin")
    File.mkdir_p!(src)
    File.mkdir_p!(ebin)
    File.rename!(Path.join(root, "native_probe.erl"), Path.join(src, "native_probe.erl"))
    File.write!(Path.join(ebin, "native_probe.beam"), beam)
    assert {:ok, [{"native_probe", ^beam}]} = Packer.BeamFiles.collect(root, ebin)

    File.mkdir_p!(Path.join(root, "c_src"))
    assert {:error, reason} = Packer.BeamFiles.collect(root, ebin)
    assert reason =~ "native code"
    File.rm_rf!(Path.join(root, "c_src"))

    File.mkdir_p!(Path.join(root, "priv"))
    File.write!(Path.join(root, "priv/native.so"), "not a BEAM")
    assert {:error, reason} = Packer.BeamFiles.collect(root, ebin)
    assert reason =~ "unpackaged priv"
  end

  defp compile_erlang!(root, name, function) do
    compile_source!(root, name, "-module(#{name}).\n-export([handle/1]).\n#{function}\n")
  end

  defp compile_source!(root, name, source) do
    path = Path.join(root, "#{name}.erl")
    File.write!(path, source)
    {output, status} = System.cmd("erlc", ["-o", root, path], stderr_to_stdout: true)
    assert status == 0, output
    File.read!(Path.join(root, "#{name}.beam"))
  end
end
