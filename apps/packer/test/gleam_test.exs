defmodule Packer.GleamTest do
  use ExUnit.Case, async: false

  @project Path.expand("../../../examples/gleam_worker", __DIR__)
  @options [
    project: @project,
    gleam: true,
    entry: "amber_worker",
    function: "handle",
    protocol: "midgard.bytes.v1"
  ]

  test "production Gleam shipment preserves exact names and locked dependency ownership" do
    if gleam = System.find_executable("gleam") do
      output =
        Path.join(
          System.tmp_dir!(),
          "gleam-artifact-#{System.unique_integer([:positive])}.midgard"
        )

      try do
        assert {:ok, ^output} = Packer.pack(@options ++ [gleam_bin: gleam, output: output])
        assert {:ok, manifest} = Packer.Verifier.verify(output)
        assert manifest["format_version"] == 2
        assert manifest["compiler"]["gleam_version"] =~ ~r/^\d/
        refute Map.has_key?(manifest["compiler"], "elixir_version")

        assert manifest["entrypoint"] == %{
                 "arity" => 1,
                 "module" => "amber_worker",
                 "function" => "handle",
                 "protocol" => "midgard.bytes.v1"
               }

        assert Enum.map(manifest["modules"], & &1["name"]) == ["amber_helper", "amber_worker"]

        assert manifest["dependencies"] == [
                 %{"app" => "amber_helper", "version" => "0.2.0", "modules" => ["amber_helper"]}
               ]

        assert {:ok, %{"execution" => "not_verified"}} = Packer.Profile.report(output)
        refute File.exists?(Path.join(output, "modules/amber_worker@@main.beam"))

        manifest_file = Path.join(output, "manifest.json")
        original = File.read!(manifest_file)
        tampered = put_in(manifest["compiler"]["elixir_version"], System.version())
        File.write!(manifest_file, Packer.JSON.encode(tampered))
        assert {:error, _} = Packer.Verifier.verify(output)
        File.write!(manifest_file, original)
      after
        File.rm_rf!(output)
      end
    else
      assert {:error, reason} = Packer.pack(@options)
      assert reason =~ "gleam executable not found"
    end
  end

  test "requires a versioned binary protocol, not an implicit Elixir SDK" do
    assert {:error, reason} =
             Packer.pack(
               project: @project,
               gleam: true,
               entry: "amber_worker",
               function: "handle"
             )

    assert reason =~ "--protocol"
  end

  test "rejects native sources and missing lock before compilation" do
    root = Path.join(System.tmp_dir!(), "gleam-safety-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    try do
      File.cp_r!(@project, root)
      File.mkdir_p!(Path.join(root, "vendor/amber_helper/c_src"))
      assert {:error, reason} = Packer.pack(Keyword.put(@options, :project, root))
      assert reason =~ "native code"
      File.rm_rf!(Path.join(root, "vendor/amber_helper/c_src"))
      File.rm!(Path.join(root, "manifest.toml"))
      assert {:error, reason} = Packer.pack(Keyword.put(@options, :project, root))
      assert reason =~ "manifest.toml"
      File.cp!(Path.join(@project, "manifest.toml"), Path.join(root, "manifest.toml"))

      File.write!(
        Path.join(root, "gleam.toml"),
        "target = \"javascript\"\n" <> File.read!(Path.join(root, "gleam.toml"))
      )

      assert {:error, reason} = Packer.pack(Keyword.put(@options, :project, root))
      assert reason =~ "Erlang-target"
    after
      File.rm_rf!(root)
    end
  end
end
