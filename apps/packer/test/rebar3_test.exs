defmodule Packer.Rebar3Test do
  use ExUnit.Case, async: false

  @project Path.expand("../../../examples/erlang_worker", __DIR__)

  test "standalone rebar3 app and Midgard checkout produce exact-name BEAMs" do
    options = [
      project: @project,
      entry: "erlang_worker",
      function: "handle",
      protocol: "midgard.bytes.v1"
    ]

    rebar3 = System.get_env("MIDGARD_REBAR3") || System.find_executable("rebar3")

    if rebar3 do
      output =
        Path.join(
          System.tmp_dir!(),
          "rebar3-artifact-#{System.unique_integer([:positive])}.midgard"
        )

      skip_output = output <> "-skip-compile"

      try do
        assert {:ok, ^output} = Packer.pack(options ++ [rebar3: rebar3, output: output])
        assert {:ok, manifest} = Packer.Verifier.verify(output)
        assert manifest["entrypoint"]["module"] == "erlang_worker"
        assert manifest["entrypoint"]["function"] == "handle"
        assert manifest["entrypoint"]["protocol"] == "midgard.bytes.v1"
        assert Enum.map(manifest["modules"], & &1["name"]) == ["erlang_worker", "midgard"]

        assert manifest["dependencies"] ==
                 [
                   %{
                     "app" => "midgard",
                     "modules" => ["midgard"],
                     "version" => "0.3.0"
                   }
                 ]

        assert {:ok, %{"execution" => "not_verified"}} = Packer.Profile.report(output)

        assert {:ok, ^skip_output} =
                 Packer.pack(
                   options ++ [skip_compile: true, rebar3: "missing-rebar3", output: skip_output]
                 )

        assert {:ok, _manifest} = Packer.Verifier.verify(skip_output)
      after
        File.rm_rf!(output)
        File.rm_rf!(skip_output)
      end
    else
      assert {:error, reason} = Packer.pack(options)
      assert reason =~ "rebar3 is required"
    end
  end

  test "uses the active rebar3 source when stale lib and checkout builds coexist" do
    root = Path.join(System.tmp_dir!(), "rebar3-stale-#{System.unique_integer([:positive])}")
    output = Path.join(root, "out.midgard")

    try do
      File.mkdir_p!(Path.join(root, "src"))
      File.write!(Path.join(root, "rebar.config"), "{deps, []}.\n")
      File.write!(Path.join(root, "src/demo.app.src"), "")
      write_app(root, "lib", "demo", "0.1.0", :demo)
      write_app(root, "lib", "sdk", "2.0.0", :sdk)
      write_app(root, "checkouts", "sdk", "1.0.0", :sdk)

      options = [
        project: root,
        entry: "demo",
        function: "handle",
        protocol: "midgard.bytes.v1",
        skip_compile: true,
        output: output
      ]

      assert {:ok, ^output} = Packer.pack(options)
      assert {:ok, manifest} = Packer.Verifier.verify(output)
      assert [%{"app" => "sdk", "version" => "2.0.0"}] = manifest["dependencies"]

      File.rm_rf!(output)
      File.mkdir_p!(Path.join(root, "_checkouts/sdk"))
      assert {:ok, ^output} = Packer.pack(options)
      assert {:ok, manifest} = Packer.Verifier.verify(output)
      assert [%{"app" => "sdk", "version" => "1.0.0"}] = manifest["dependencies"]
    after
      File.rm_rf!(root)
    end
  end

  defp write_app(root, kind, app, version, module) do
    ebin = Path.join([root, "_build/default", kind, app, "ebin"])
    File.mkdir_p!(ebin)
    src = Path.join([root, "_build/default", kind, app, "src"])
    File.mkdir_p!(src)
    File.write!(Path.join(src, "#{module}.erl"), "-module(#{module}).\n")

    forms = [
      {:attribute, 1, :module, module},
      {:attribute, 2, :export, [handle: 1]},
      {:function, 3, :handle, 1, [{:clause, 3, [{:var, 3, :X}], [], [{:var, 3, :X}]}]}
    ]

    {:ok, ^module, beam} = :compile.forms(forms, [:debug_info])
    File.write!(Path.join(ebin, "#{module}.beam"), beam)

    File.write!(
      Path.join(ebin, "#{app}.app"),
      ~s({application, #{app}, [{vsn, "#{version}"}, {modules, [#{module}]}]}.\n)
    )
  end

  test "rejects missing protocol rather than mislabeling HTTP-shaped Erlang bytes" do
    assert {:error, reason} =
             Packer.pack(project: @project, entry: "erlang_worker", function: "handle")

    assert reason =~ "--protocol"
  end
end
