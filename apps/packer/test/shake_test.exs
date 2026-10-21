defmodule Packer.ShakeTest do
  use ExUnit.Case, async: false

  # Compiles fixture modules in memory, with debug info, without loading them.
  defp compile(source) do
    previous = Code.compiler_options()
    # mix test compiles without debug info; shaking needs it.
    Code.put_compiler_option(:ignore_module_conflict, true)
    Code.put_compiler_option(:debug_info, true)

    try do
      for {module, bytes} <- Code.compile_string(source) do
        :code.purge(module)
        :code.delete(module)
        {Atom.to_string(module), bytes}
      end
    after
      Code.compiler_options(previous)
    end
  end

  defp records(pairs, owner \\ "fixture"),
    do: Enum.map(pairs, fn {name, bytes} -> %{name: name, owner: owner, bytes: bytes} end)

  defp exports(bytes) do
    {:ok, {_, [exports: exports]}} = :beam_lib.chunks(bytes, [:exports])
    exports -- [module_info: 0, module_info: 1]
  end

  test "drops unreachable functions and modules, keeping imports closed" do
    modules =
      compile("""
      defmodule ShakeFixture.Entry do
        def call(x), do: ShakeFixture.Used.go(x)
        def unused(x), do: ShakeFixture.Unused.go(x)
      end

      defmodule ShakeFixture.Used do
        def go(x), do: {:ok, x}
        def other, do: ShakeFixture.Unused.go(1)
      end

      defmodule ShakeFixture.Unused do
        def go(x), do: x
      end
      """)

    assert {:ok, shaken, stats} =
             Packer.Shake.run(records(modules), {ShakeFixture.Entry, :call, 1}, cache: false)

    kept = Map.new(shaken, &{&1.name, &1.bytes})

    assert Map.keys(kept) == ["Elixir.ShakeFixture.Entry", "Elixir.ShakeFixture.Used"]
    assert exports(kept["Elixir.ShakeFixture.Entry"]) == [call: 1]
    assert exports(kept["Elixir.ShakeFixture.Used"]) == [go: 1]
    assert stats.modules == {3, 2}
    {:ok, _, chunks} = :beam_lib.all_chunks(kept["Elixir.ShakeFixture.Used"])
    refute Enum.any?(chunks, &(elem(&1, 0) == ~c"Dbgi"))
  end

  test "keeps targets of dynamic calls narrowed by literals" do
    modules =
      compile("""
      defmodule ShakeFixture.Dispatch do
        def call(x) do
          # A module built from a literal, as Elixir does to avoid compile-time dependencies.
          target = :erlang.binary_to_atom("Elixir.ShakeFixture.Target")
          target.run(x)
        end
      end

      defmodule ShakeFixture.Target do
        def run(x), do: x * 2
        def other, do: :dropped
      end
      """)

    assert {:ok, shaken, _stats} =
             Packer.Shake.run(records(modules), {ShakeFixture.Dispatch, :call, 1}, cache: false)

    kept = Map.new(shaken, &{&1.name, &1.bytes})
    assert exports(kept["Elixir.ShakeFixture.Target"]) == [run: 1]
  end

  test "keep entries become roots" do
    modules =
      compile("""
      defmodule ShakeFixture.Root do
        def call(x), do: x
      end

      defmodule ShakeFixture.Plugin do
        def a, do: 1
        def b(x), do: x
      end
      """)

    assert {:ok, shaken, _} =
             Packer.Shake.run(records(modules), {ShakeFixture.Root, :call, 1},
               cache: false,
               keep: [ShakeFixture.Plugin]
             )

    plugin = Enum.find(shaken, &(&1.name == "Elixir.ShakeFixture.Plugin"))
    assert Enum.sort(exports(plugin.bytes) -- [__info__: 1]) == [a: 0, b: 1]
  end

  test "fails when the entrypoint is missing" do
    modules = compile("defmodule ShakeFixture.Lonely, do: def(call(x), do: x)")

    assert {:error, message} =
             Packer.Shake.run(records(modules), {ShakeFixture.Lonely, :nope, 1}, cache: false)

    assert message =~ "not defined"
  end

  test "strip keeps what libbeam and the verifier need, uncompressed" do
    [{_, bytes}] = compile("defmodule ShakeFixture.Strip, do: def(go, do: :ok)")
    assert {:ok, stripped} = Packer.Shake.strip(bytes)
    assert <<"FOR1", _::binary>> = stripped
    {:ok, _, chunks} = :beam_lib.all_chunks(stripped)
    ids = Enum.map(chunks, &elem(&1, 0))
    assert ~c"Attr" in ids and ~c"CInf" in ids and ~c"Code" in ids
    refute ~c"Dbgi" in ids or ~c"Docs" in ids or ~c"ExCk" in ids
  end

  test "the runtime closure includes protocol implementations" do
    modules = compile("defmodule ShakeFixture.Enums, do: def(call(map), do: Enum.map(map, & &1))")

    assert {:ok, collected, _records} = Packer.RuntimeClosure.collect("fixture", modules, [])
    names = MapSet.new(collected, & &1.name)
    assert "Elixir.Enumerable.Map" in names
    assert "Elixir.Inspect.Map" in names
  end

  @tag timeout: 180_000
  test "shaken Elixir and stdlib modules behave like the originals on OTP" do
    modules =
      compile("""
      defmodule ShakeFixture.Worker do
        defmodule Point, do: defstruct(x: 0, y: 0)

        def call(:inspect), do: inspect(%{a: [1, :b, "c", 2.5], r: 1..3, s: MapSet.new([1, 2]), p: %Point{x: 1}})
        def call(:enum), do: inspect([Enum.map(%{a: 1}, fn {k, v} -> {k, v * 2} end), Enum.sum(1..10), MapSet.new([3, 1]) |> Enum.to_list()])
        def call(:interp), do: "\#{123} \#{:atom} \#{1.5} \#{[?a]}"
        def call(:uri), do: URI.parse("https://example.com:8443/a?x=1") |> URI.to_string()
        def call(:rescue) do
          try do
            Map.fetch!(%{}, :missing)
          rescue
            e -> Exception.message(e)
          end
        end
      end
      """)

    {:ok, closure, _records} = Packer.RuntimeClosure.collect("fixture", modules, [])

    assert {:ok, shaken, stats} =
             Packer.Shake.run(closure, {ShakeFixture.Worker, :call, 1}, cache: false)

    {before, after_shaking} = stats.modules
    assert after_shaking < before / 2

    calls = [:inspect, :enum, :interp, :uri, :rescue]

    expected =
      in_peer(modules, fn peer ->
        Enum.map(calls, &:peer.call(peer, ShakeFixture.Worker, :call, [&1]))
      end)

    # Boot :elixir from its real modules, then replace every shaken non-OTP module
    # (Elixir, consolidated protocols, the fixture); OTP stays as booted.
    elixir = for record <- shaken, not otp?(record.owner), do: {record.name, record.bytes}

    actual =
      in_peer(elixir, fn peer ->
        Enum.map(calls, &:peer.call(peer, ShakeFixture.Worker, :call, [&1]))
      end)

    assert actual == expected
  end

  defp otp?(owner) do
    case :code.lib_dir(String.to_atom(owner)) do
      {:error, _} -> false
      dir -> List.starts_with?(dir, :code.root_dir()) and owner != "elixir"
    end
  end

  defp otp?(owner) do
    case :code.lib_dir(String.to_atom(owner)) do
      {:error, _} -> false
      dir -> List.starts_with?(dir, :code.root_dir())
    end
  end

  defp in_peer(modules, fun) do
    ebin = :code.lib_dir(:elixir) |> Path.join("ebin") |> String.to_charlist()
    {:ok, peer, _node} = :peer.start_link(%{connection: :standard_io, args: [~c"-pa", ebin]})

    try do
      {:ok, _} = :peer.call(peer, :application, :ensure_all_started, [:elixir])

      for {name, bytes} <- modules do
        module = String.to_atom(name)
        :peer.call(peer, :code, :purge, [module])
        {:module, ^module} = :peer.call(peer, :code, :load_binary, [module, ~c"shaken", bytes])
      end

      fun.(peer)
    after
      :peer.stop(peer)
    end
  end
end
