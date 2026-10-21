defmodule Packer.GleamTest do
  use ExUnit.Case, async: false

  @project Path.expand("../../../examples/gleam_worker", __DIR__)
  @options [
    project: @project,
    gleam: true,
    entry: "gleam_worker",
    function: "handle",
    protocol: "midgard.bytes.v1"
  ]

  test "production Gleam shipment preserves exact names and locked Midgard dependency ownership" do
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
                 "module" => "gleam_worker",
                 "function" => "handle",
                 "protocol" => "midgard.bytes.v1"
               }

        assert Enum.map(manifest["modules"], & &1["name"]) == ["gleam_worker", "midgard"]

        assert manifest["dependencies"] == [
                 %{"app" => "midgard_gleam", "version" => "0.3.0", "modules" => ["midgard"]}
               ]

        assert {:ok, %{"execution" => "not_verified"}} = Packer.Profile.report(output)
        refute File.exists?(Path.join(output, "modules/gleam_worker@@main.beam"))

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
               entry: "gleam_worker",
               function: "handle"
             )

    assert reason =~ "--protocol"
  end

  test "rejects native sources and missing lock before compilation" do
    workspace =
      Path.join(System.tmp_dir!(), "gleam-safety-#{System.unique_integer([:positive])}")

    project = Path.join(workspace, "examples/gleam_worker")
    dependency = Path.join(project, "build/packages/midgard_gleam")
    library = Path.expand("../../../packages/gleam", __DIR__)

    if System.find_executable("gleam") do
      File.mkdir_p!(Path.dirname(project))
      File.mkdir_p!(Path.dirname(dependency))

      try do
        File.cp_r!(@project, project)
        File.cp_r!(library, dependency)
        File.mkdir_p!(Path.join(dependency, "c_src"))
        assert {:error, reason} = Packer.pack(Keyword.put(@options, :project, project))
        assert reason =~ "native code"
        File.rm_rf!(Path.join(dependency, "c_src"))
        File.rm!(Path.join(project, "manifest.toml"))
        assert {:error, reason} = Packer.pack(Keyword.put(@options, :project, project))
        assert reason =~ "manifest.toml"
        File.cp!(Path.join(@project, "manifest.toml"), Path.join(project, "manifest.toml"))

        File.write!(
          Path.join(project, "gleam.toml"),
          "target = \"javascript\"\n" <> File.read!(Path.join(project, "gleam.toml"))
        )

        assert {:error, reason} = Packer.pack(Keyword.put(@options, :project, project))
        assert reason =~ "Erlang-target"
      after
        File.rm_rf!(workspace)
      end
    else
      assert {:error, reason} = Packer.pack(@options)
      assert reason =~ "gleam executable not found"
    end
  end
end
