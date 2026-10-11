defmodule Packer.Rebar3Test do
  use ExUnit.Case, async: false

  @project Path.expand("../../../examples/erlang_worker", __DIR__)

  test "standalone rebar3 app and checkout dependency produce exact-name BEAMs" do
    options = [
      project: @project,
      entry: "erlang_worker",
      function: "handle",
      protocol: "raw.bytes.v1"
    ]

    rebar3 = System.get_env("MIDGARD_REBAR3") || System.find_executable("rebar3")

    if rebar3 do
      output =
        Path.join(
          System.tmp_dir!(),
          "rebar3-artifact-#{System.unique_integer([:positive])}.midgard"
        )

      try do
        assert {:ok, ^output} = Packer.pack(options ++ [rebar3: rebar3, output: output])
        assert {:ok, manifest} = Packer.Verifier.verify(output)
        assert manifest["entrypoint"]["module"] == "erlang_worker"
        assert manifest["entrypoint"]["function"] == "handle"
        assert Enum.map(manifest["modules"], & &1["name"]) == ["erlang_helper", "erlang_worker"]

        assert manifest["dependencies"] ==
                 [
                   %{
                     "app" => "erlang_helper",
                     "modules" => ["erlang_helper"],
                     "version" => "0.2.0"
                   }
                 ]

        assert {:ok, %{"execution" => "not_verified"}} = Packer.Profile.report(output)
      after
        File.rm_rf!(output)
      end
    else
      assert {:error, reason} = Packer.pack(options)
      assert reason =~ "rebar3 is required"
    end
  end

  test "rejects missing protocol rather than mislabeling raw Erlang bytes" do
    assert {:error, reason} =
             Packer.pack(project: @project, entry: "erlang_worker", function: "handle")

    assert reason =~ "--protocol"
  end
end
