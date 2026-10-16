defmodule PackerTest do
  use ExUnit.Case, async: false

  setup do
    root = Path.join(System.tmp_dir!(), "packer-fixture-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "rejects malformed pack options at the public boundary" do
    assert {:error, "expected keyword pack options"} = Packer.pack([:not_an_option])
    assert {:error, "expected keyword pack options"} = Packer.pack(%{project: "fixture"})
  end

  test "versioned exact-name BEAM artifact is deterministic, inspectable and owned", %{root: root} do
    {entry, beam} = compile_fixture("def __midgard_call__(bytes), do: bytes")
    {helper, helper_beam} = compile_fixture("def hello, do: \"hello\"")

    modules = [
      %{name: entry, owner: "fixture", bytes: beam},
      %{name: helper, owner: "dependency", bytes: helper_beam}
    ]

    deps = [%{app: "dependency", version: "1.2.3", modules: [helper]}]
    first = Path.join(root, "first.midgard")
    second = Path.join(root, "second.midgard")

    assert {:ok, ^first} = Packer.Artifact.build(first, "fixture", entry, modules, deps)
    assert {:ok, ^second} = Packer.Artifact.build(second, "fixture", entry, modules, deps)

    assert File.read!(Path.join(first, "manifest.json")) ==
             File.read!(Path.join(second, "manifest.json"))

    assert File.read!(Path.join(first, "modules/#{entry}.beam")) == beam

    assert {:ok, manifest} = Packer.Verifier.verify(first)
    assert manifest["format_version"] == 1
    assert manifest["entrypoint"]["module"] == entry
    assert manifest["target"]["execution"] == "not_verified"

    assert manifest["dependencies"] == [
             %{"app" => "dependency", "version" => "1.2.3", "modules" => [helper]}
           ]

    assert Enum.map(manifest["modules"], & &1["name"]) == Enum.sort([entry, helper])
    assert {:ok, report} = Packer.Profile.report(first)
    assert report["execution"] == "not_verified"
  end

  test "generic Packer entrypoint accepts a different binary protocol", %{root: root} do
    {entry, beam} = compile_fixture("def call(bytes), do: bytes")
    path = Path.join(root, "generic.midgard")
    record = %{name: entry, owner: "fixture", bytes: beam}

    assert {:ok, ^path} =
             Packer.Artifact.build(path, "fixture", entry, [record], [],
               function: "call",
               protocol: "raw.bytes.v1"
             )

    assert {:ok, %{"entrypoint" => %{"function" => "call", "protocol" => "raw.bytes.v1"}}} =
             Packer.Verifier.verify(path)
  end

  test "rejects corrupted and unlisted artifact files", %{root: root} do
    {entry, beam} = compile_fixture("def __midgard_call__(bytes), do: bytes")
    path = Path.join(root, "corrupt.midgard")

    assert {:ok, ^path} =
             Packer.Artifact.build(
               path,
               "fixture",
               entry,
               [%{name: entry, owner: "fixture", bytes: beam}],
               []
             )

    beam_path = Path.join(path, "modules/#{entry}.beam")
    File.write!(beam_path, <<0>> <> binary_part(beam, 1, byte_size(beam) - 1))
    assert {:error, _} = Packer.Verifier.verify(path)

    File.write!(beam_path, beam <> <<0>>)
    assert {:error, _} = Packer.Verifier.verify(path)

    File.write!(beam_path, beam)
    File.write!(Path.join(path, "modules/unlisted.beam"), beam)
    assert {:error, _} = Packer.Verifier.verify(path)
  end

  test "rejects unsupported versions, missing entrypoints and duplicate names", %{root: root} do
    {entry, beam} = compile_fixture("def __midgard_call__(bytes), do: bytes")
    path = Path.join(root, "version.midgard")
    record = %{name: entry, owner: "fixture", bytes: beam}
    assert {:error, reason} = Packer.Artifact.build(path, "fixture", entry, [record, record], [])
    assert reason =~ "duplicate"
    assert {:ok, ^path} = Packer.Artifact.build(path, "fixture", entry, [record], [])

    manifest_path = Path.join(path, "manifest.json")
    {:ok, manifest} = Packer.Verifier.verify(path)
    File.write!(manifest_path, Packer.JSON.encode(%{manifest | "format_version" => 99}))
    assert {:error, _} = Packer.Verifier.verify(path)

    {wrong, wrong_beam} = compile_fixture("def other(bytes), do: bytes")

    assert {:error, reason} =
             Packer.Artifact.build(
               Path.join(root, "missing.midgard"),
               "fixture",
               wrong,
               [%{name: wrong, owner: "fixture", bytes: wrong_beam}],
               []
             )

    assert reason =~ "entrypoint"
  end

  test "malformed manifest JSON returns errors without evaluating source", %{
    root: root
  } do
    {entry, beam} = compile_fixture("def __midgard_call__(bytes), do: bytes")
    path = Path.join(root, "untrusted.midgard")

    assert {:ok, ^path} =
             Packer.Artifact.build(
               path,
               "fixture",
               entry,
               [%{name: entry, owner: "fixture", bytes: beam}],
               []
             )

    {:ok, manifest} = Packer.Verifier.verify(path)
    file = Path.join(path, "manifest.json")

    for malformed <- [
          Map.put(manifest, "modules", [42]),
          put_in(manifest, ["entrypoint", "module"], 42),
          Map.put(manifest, "dependencies", ["not a dependency"]),
          put_in(manifest, ["entrypoint", "protocol"], nil),
          Map.put(manifest, "required_capabilities", ["ambient_file"])
        ] do
      File.write!(file, Packer.JSON.encode(malformed))
      assert {:error, _reason} = Packer.Verifier.verify(path)
    end
  end

  test "rejects direct host authority even though Elixir can compile it", %{root: root} do
    for expression <- ["File.read!(bytes)", ":erlang.load_nif(bytes, 0)"] do
      {entry, beam} = compile_fixture("def __midgard_call__(bytes), do: #{expression}")
      path = Path.join(root, "unsafe-#{System.unique_integer([:positive])}.midgard")

      assert {:error, reason} =
               Packer.Artifact.build(
                 path,
                 "fixture",
                 entry,
                 [%{name: entry, owner: "fixture", bytes: beam}],
                 []
               )

      assert reason =~ "host-authority import"
      refute File.exists?(path)
    end
  end

  test "refuses symlink destinations, including dangling links", %{root: root} do
    {entry, beam} = compile_fixture("def __midgard_call__(bytes), do: bytes")
    record = %{name: entry, owner: "fixture", bytes: beam}
    path = Path.join(root, "linked.midgard")
    File.ln_s!(Path.join(root, "missing.midgard"), path)

    assert {:error, "output cannot be a symlink"} =
             Packer.Artifact.build(path, "fixture", entry, [record], [])

    assert {:ok, %{type: :symlink}} = File.lstat(path)
    refute File.exists?(Path.join(root, "missing.midgard"))
  end

  test "a failed rebuild preserves the last verified artifact", %{root: root} do
    {entry, beam} = compile_fixture("def __midgard_call__(bytes), do: bytes")
    path = Path.join(root, "stable.midgard")
    record = %{name: entry, owner: "fixture", bytes: beam}
    assert {:ok, ^path} = Packer.Artifact.build(path, "fixture", entry, [record], [])
    original = File.read!(Path.join(path, "manifest.json"))

    {unsafe, unsafe_beam} = compile_fixture("def invoke(bytes), do: File.read!(bytes)")
    bad_record = %{name: unsafe, owner: "fixture", bytes: unsafe_beam}
    assert {:error, _} = Packer.Artifact.build(path, "fixture", entry, [record, bad_record], [])
    assert File.read!(Path.join(path, "manifest.json")) == original
    assert {:ok, _} = Packer.Verifier.verify(path)
  end

  test "a tiny binary BEAM has no known current-core static blockers, not execution proof", %{
    root: root
  } do
    {entry, beam} = compile_fixture("def __midgard_call__(bytes), do: bytes")
    path = Path.join(root, "positive-static.midgard")

    assert {:ok, ^path} =
             Packer.Artifact.build(
               path,
               "fixture",
               entry,
               [%{name: entry, owner: "fixture", bytes: beam}],
               []
             )

    assert {:ok, report} = Packer.Profile.report(path)
    assert report["known_unsupported_current_core"] == []
    assert report["unresolved_imports"] == []
    assert report["execution"] == "not_verified"
    assert {:ok, note} = Packer.Profile.current_core_check(path)
    assert note =~ "libbeam execution still NOT VERIFIED"
  end

  test "native imports and local closures are conditional support, not static blockers", %{
    root: root
  } do
    {entry, beam} =
      compile_fixture("""
      def __midgard_call__(bytes) do
        fun = fn -> bytes end
        {fun, self(), make_ref(), is_function(fun), Integer.to_string(42)}
      end
      """)

    path = Path.join(root, "conditional.midgard")

    assert {:ok, ^path} =
             Packer.Artifact.build(
               path,
               "fixture",
               entry,
               [%{name: entry, owner: "fixture", bytes: beam}],
               []
             )

    assert {:ok, report} = Packer.Profile.report(path)
    assert report["profile_revision"] == "libbeam:b023b770"
    assert report["known_unsupported_current_core"] == []
    refute Enum.any?(report["unresolved_imports"], &String.contains?(&1, "erlang:self/0"))
    refute Enum.any?(report["unresolved_imports"], &String.contains?(&1, "erlang:make_ref/0"))

    assert Enum.any?(
             report["conditionally_supported_operations"],
             &String.contains?(&1, "make_fun3")
           )

    assert report["execution"] == "not_verified"
  end

  test "current-core profile flags known unsupported map bytecode, not execution", %{root: root} do
    {entry, beam} = compile_fixture("def __midgard_call__(bytes), do: %{body: bytes}")
    path = Path.join(root, "maps.midgard")

    assert {:ok, ^path} =
             Packer.Artifact.build(
               path,
               "fixture",
               entry,
               [%{name: entry, owner: "fixture", bytes: beam}],
               []
             )

    assert {:ok, report} = Packer.Profile.report(path)

    assert Enum.any?(
             report["known_unsupported_current_core"],
             &String.contains?(&1, "opcode put_map")
           )

    assert {:error, reason} = Packer.Profile.current_core_check(path)
    assert reason =~ "static current-core preflight blocked"
  end

  defp compile_fixture(functions) do
    module = Module.concat([PackerFixture, "Worker#{System.unique_integer([:positive])}"])
    [{^module, beam}] = Code.compile_string("defmodule #{inspect(module)} do\n#{functions}\nend")
    {Atom.to_string(module), beam}
  end
end
