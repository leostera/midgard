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
                     "version" => "0.2.0"
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

  test "rejects missing protocol rather than mislabeling HTTP-shaped Erlang bytes" do
    assert {:error, reason} =
             Packer.pack(project: @project, entry: "erlang_worker", function: "handle")

    assert reason =~ "--protocol"
  end
end
