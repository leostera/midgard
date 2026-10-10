defmodule Midgard.CLI.ConfigTest do
  use ExUnit.Case, async: true

  test "requires a midgard.config.exs file" do
    root = Path.join(System.tmp_dir!(), "midgard-config-#{System.unique_integer([:positive])}")
    assert {:error, reason} = Midgard.CLI.Config.load(root)
    assert reason =~ "midgard.config.exs is required"
  end

  test "example declares a worker entry module and provisional libbeam target" do
    root = Path.expand("../../../examples/hello_worker", __DIR__)
    assert {:ok, config} = Midgard.CLI.Config.load(root)
    assert Midgard.CLI.Config.entry(config) == HelloWorker
    assert config[:target] == :libbeam
  end
end
