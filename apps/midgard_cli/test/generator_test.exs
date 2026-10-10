defmodule Midgard.CLI.GeneratorTest do
  use ExUnit.Case, async: true

  test "creates a complete worker project without overwriting existing files" do
    destination =
      Path.join(System.tmp_dir!(), "midgard-new-#{System.unique_integer([:positive])}")

    root = Midgard.CLI.Generator.default_root()

    try do
      assert {:ok, ^destination} = Midgard.CLI.Generator.generate("my_worker", destination, root)

      assert File.read!(Path.join(destination, "midgard.config.exs")) =~
               "entry: MyWorker, target: :libbeam"

      assert File.read!(Path.join(destination, "mix.exs")) =~ "packer: [entry: MyWorker]"
      assert File.read!(Path.join(destination, "lib/my_worker.ex")) =~ "Midgard.Worker"

      assert File.read!(Path.join(destination, "lib/my_worker/greeting.ex")) =~
               "defmodule MyWorker.Greeting"

      assert File.regular?(Path.join(destination, "test/my_worker_test.exs"))
      assert {:error, reason} = Midgard.CLI.Generator.generate("my_worker", destination, root)
      assert reason =~ "already exists"
    after
      File.rm_rf!(destination)
    end
  end

  test "rejects unsafe names and a missing checkout" do
    root = Midgard.CLI.Generator.default_root()
    assert {:error, _} = Midgard.CLI.Generator.generate("../bad", "/tmp/nope", root)
    assert {:error, _} = Midgard.CLI.Generator.generate("good", "/tmp/nope", "/missing")
  end
end
