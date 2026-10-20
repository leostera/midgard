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

      mix = File.read!(Path.join(destination, "mix.exs"))
      assert mix =~ "packer: [entry: MyWorker]"
      assert mix =~ ~s(elixir: "~> 1.21.0-dev")
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

  test "Git archive generator pins runtime and build dependencies to one revision" do
    revision = String.duplicate("a", 40)

    destination =
      Path.join(System.tmp_dir!(), "midgard-git-new-#{System.unique_integer([:positive])}")

    try do
      assert {:ok, ^destination} =
               Midgard.CLI.Generator.generate_from_git("git_worker", destination, revision)

      mix = File.read!(Path.join(destination, "mix.exs"))
      assert length(String.split(mix, ~s(ref: "#{revision}"))) == 3
      assert mix =~ ~s(subdir: "apps/midgard")
      assert mix =~ ~s(subdir: "apps/packer")
      refute mix =~ ":midgard_cli"

      assert {:error, _} =
               Midgard.CLI.Generator.generate_from_git("bad", "/tmp/unused", "not-a-sha")
    after
      File.rm_rf!(destination)
    end
  end

  test "Hex archive generator emits versioned package dependencies" do
    destination =
      Path.join(System.tmp_dir!(), "midgard-hex-new-#{System.unique_integer([:positive])}")

    try do
      assert {:ok, ^destination} =
               Midgard.CLI.Generator.generate_from_hex("hex_worker", destination)

      mix = File.read!(Path.join(destination, "mix.exs"))
      assert mix =~ ~s({:midgard, "~> 0.2"})
      assert mix =~ ~s(hex: "midgard_packer", version: "~> 0.2")
      refute mix =~ ":midgard_cli"
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
