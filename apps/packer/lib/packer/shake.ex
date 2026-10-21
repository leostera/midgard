defmodule Packer.Shake do
  @moduledoc """
  Function-level tree shaking of a collected closure (RFD0003).

  Walks the function graph from the entrypoint through every module, rebuilds
  each module with only its reachable functions, and drops modules with none.
  Removing unreachable functions removes their imports, so the result still
  satisfies libbeam's whole-group rule that every import resolves; a closure
  check fails the build otherwise.

  Dynamic calls are resolved when a literal narrows the target:

    * `Mod.f(...)` with a computed module and known `f/a` reaches `f/a` in
      every module named by an atom in reachable code. A module value can only
      come from such an atom, so protocol dispatch and exception callbacks
      follow from this rule.
    * `binary_to_atom/1,2` and `list_to_atom/1` of a literal count as that atom.
    * `m.fun(...)` with a literal module and computed function keeps that
      module's exports of that arity.
    * Calls with neither the module nor the function known are reported in
      `unknown_target_sites`, not followed. Verify the result on OTP.

  Elixir modules are rebuilt from their Core Erlang debug info with their own
  compile options; Erlang modules from abstract code. A module that cannot be
  rebuilt is kept whole, with its non-executable chunks stripped. Rebuilds and
  per-module indexes are cached by content hash.
  """

  @cache_version 2

  @atom_makers [
    {:erlang, :binary_to_atom, 1},
    {:erlang, :binary_to_atom, 2},
    {:erlang, :list_to_atom, 1},
    {:erlang, :binary_to_existing_atom, 1},
    {:erlang, :binary_to_existing_atom, 2},
    {:erlang, :list_to_existing_atom, 1}
  ]

  # Chunks libbeam and Packer's verifier need; everything else is dropped.
  @kept_chunks ~c"AtU8 Code StrT ImpT ExpT FunT LitT LocT Attr CInf Line Type Meta"
               |> :string.lexemes(~c" ")

  @type module_record :: %{name: String.t(), owner: String.t(), bytes: binary()}
  @type stats :: %{
          modules: {non_neg_integer(), non_neg_integer()},
          functions: {non_neg_integer(), non_neg_integer()},
          bytes: {non_neg_integer(), non_neg_integer()},
          kept_whole: [String.t()],
          unknown_target_sites: [String.t()],
          runtime_atom_sites: [String.t()]
        }

  @doc """
  Shakes `modules` from `root` (`{module, function, arity}`).

  Options: `:keep` (modules, whose exports all stay, or `{m, f, a}` tuples)
  and `:cache` (a directory, or `false`).
  """
  @spec run([module_record()], {atom(), atom(), arity()}, keyword()) ::
          {:ok, [module_record()], stats()} | {:error, String.t()}
  def run(modules, {_, _, _} = root, opts \\ []) do
    cache = Keyword.get_lazy(opts, :cache, &default_cache/0)
    by_name = Map.new(modules, fn record -> {String.to_atom(record.name), record} end)
    shipped = by_name |> Map.keys() |> MapSet.new()

    with {:ok, index} <- index(by_name, shipped, cache),
         {:ok, roots} <- roots(root, Keyword.get(opts, :keep, []), index) do
      shake(by_name, index, roots, cache, MapSet.new(), 0)
    end
  end

  @doc "The per-user cache directory used when `:cache` is not given."
  def default_cache, do: :filename.basedir(:user_cache, ~c"midgard_packer") |> List.to_string()

  # A module that fails to rebuild is kept whole and all its functions become
  # roots, which can make more modules reachable; repeat until stable.
  defp shake(by_name, index, roots, cache, whole, round) when round < 5 do
    reach = walk(index, roots ++ whole_roots(index, whole))
    kept = kept_functions(reach.funs)

    {built, failed} =
      kept
      |> Enum.map(fn {module, keep} ->
        {module, by_name[module], index.modules[module], keep, MapSet.member?(whole, module),
         cache}
      end)
      |> Task.async_stream(&build/1, timeout: :infinity, ordered: false)
      |> Enum.map(fn {:ok, result} -> result end)
      |> Enum.split_with(&match?({:ok, _, _}, &1))

    failed = for {:error, module} <- failed, into: MapSet.new(), do: module

    if MapSet.size(failed) == 0 do
      rebuilt = Map.new(built, fn {:ok, module, bytes} -> {module, bytes} end)

      with :ok <- closure(rebuilt, index.shipped) do
        records =
          for {module, bytes} <- rebuilt, do: %{by_name[module] | bytes: bytes}

        {:ok, Enum.sort_by(records, & &1.name), stats(by_name, index, reach, rebuilt, whole)}
      end
    else
      shake(by_name, index, roots, cache, MapSet.union(whole, failed), round + 1)
    end
  end

  defp shake(_, _, _, _, _, _),
    do: {:error, "tree shaking did not converge; rebuild with --no-shake"}

  defp stats(by_name, index, reach, rebuilt, whole) do
    sizes = fn records -> Enum.reduce(records, 0, &(&2 + byte_size(&1))) end

    %{
      modules: {map_size(by_name), map_size(rebuilt)},
      functions: {map_size(index.funs), MapSet.size(reach.funs)},
      bytes: {sizes.(Enum.map(by_name, fn {_, r} -> r.bytes end)), sizes.(Map.values(rebuilt))},
      kept_whole: whole |> Enum.map(&Atom.to_string/1) |> Enum.sort(),
      unknown_target_sites: reach.wide_sites |> Enum.map(&mfa/1) |> Enum.sort(),
      runtime_atom_sites: reach.runtime_atoms |> Enum.map(&mfa/1) |> Enum.sort()
    }
  end

  @doc "A one-line summary of `stats`."
  def summary(%{modules: {m0, m1}, functions: {f0, f1}, bytes: {b0, b1}} = stats) do
    "Shaken: #{m0} → #{m1} modules, #{f0} → #{f1} functions, #{mb(b0)} → #{mb(b1)}" <>
      if(stats.unknown_target_sites == [],
        do: "",
        else:
          "; #{length(stats.unknown_target_sites)} calls with unknown targets were not followed"
      )
  end

  defp mb(bytes), do: :io_lib.format(~c"~.1f MB", [bytes / 1_000_000]) |> List.to_string()

  defp mfa({m, f, a}), do: "#{m}:#{f}/#{a}"

  # ------------------------------------------------------------------ roots

  defp roots({m, f, a} = root, keep, index) do
    cond do
      not Map.has_key?(index.funs, root) ->
        {:error, "entrypoint #{m}.#{f}/#{a} is not defined in the closure"}

      true ->
        extra =
          Enum.flat_map(List.wrap(keep), fn
            {km, kf, ka} ->
              [{km, kf, ka}]

            km when is_atom(km) ->
              for {ef, ea} <- Map.get(index.exports, km, MapSet.new()), do: {km, ef, ea}
          end)

        {:ok, [root | extra]}
    end
  end

  defp whole_roots(index, whole) do
    for module <- whole, {mfa, _} <- index.modules[module].funs, do: mfa
  end

  # ------------------------------------------------------------------ index

  defp index(by_name, shipped, cache) do
    results =
      by_name
      |> Enum.map(fn {module, record} -> {module, record.bytes} end)
      |> Task.async_stream(
        fn {module, bytes} -> {module, index_module(module, bytes, shipped, cache)} end,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    case for({module, {:error, reason}} <- results, do: {module, reason}) do
      [] ->
        modules = Map.new(results, fn {module, {:ok, info}} -> {module, info} end)
        funs = for {_, info} <- modules, {mfa, fun} <- info.funs, into: %{}, do: {mfa, fun}
        exports = Map.new(modules, fn {module, info} -> {module, MapSet.new(info.exports)} end)
        {:ok, %{modules: modules, funs: funs, exports: exports, shipped: shipped}}

      [{module, reason} | _] ->
        {:error, "cannot shake #{module}: #{reason}; rebuild with --no-shake"}
    end
  end

  # The shipped set is part of the key: atom literals are filtered by it.
  defp index_module(module, bytes, shipped, cache) do
    key = {:index, @cache_version, :crypto.hash(:sha256, bytes), :erlang.phash2(shipped)}

    cached(cache, key, fn ->
      case abstract_code(module, bytes) do
        {:ok, forms, backend} -> index_forms(module, forms, backend, shipped)
        {:error, _} -> index_opaque(module, bytes, shipped)
      end
    end)
  end

  # Without abstract code a module cannot be rebuilt: it ships whole, and any
  # reachable export reaches all of its imports and module atoms.
  defp index_opaque(module, bytes, shipped) do
    with {:ok, {^module, [exports: exports, imports: imports, atoms: atoms]}} <-
           :beam_lib.chunks(bytes, [:exports, :imports, :atoms]) do
      atoms = for {_, atom} <- atoms, MapSet.member?(shipped, atom), into: MapSet.new(), do: atom
      info = %{calls: imports, dyn: [], atoms: atoms, runtime_atoms: false}
      funs = Map.new(exports, fn {f, a} -> {{module, f, a}, info} end)

      {:ok,
       %{
         exports: exports,
         funs: funs,
         defined: MapSet.new(exports),
         elixir?: false,
         opaque?: true
       }}
    else
      _ -> {:error, "cannot read BEAM chunks"}
    end
  end

  defp index_forms(module, forms, backend, shipped) do
    defined = for {:function, _, f, a, _} <- forms, into: MapSet.new(), do: {f, a}

    funs =
      for {:function, _, f, a, clauses} <- forms, into: %{} do
        acc =
          scan(clauses, %{
            m: module,
            defined: defined,
            shipped: shipped,
            calls: [],
            dyn: [],
            atoms: MapSet.new(),
            runtime_atoms: false
          })

        {{module, f, a}, Map.take(acc, [:calls, :dyn, :atoms, :runtime_atoms])}
      end

    {:ok,
     %{
       exports: for({:attribute, _, :export, list} <- forms, fa <- list, do: fa),
       funs: funs,
       defined: defined,
       elixir?: backend == :elixir_erl,
       opaque?: false
     }}
  end

  defp abstract_code(module, bytes) do
    case :beam_lib.chunks(bytes, [:debug_info]) do
      {:ok, {^module, [debug_info: {:debug_info_v1, backend, data}]}} ->
        case backend.debug_info(:erlang_v1, module, data, []) do
          {:ok, forms} -> {:ok, forms, backend}
          _ -> {:error, "no abstract code"}
        end

      _ ->
        {:error, "no debug info"}
    end
  end

  # ------------------------------------------------------------------ scan

  defp scan({:call, _, {:remote, _, {:atom, _, m}, {:atom, _, f}}, args}, acc) do
    acc = acc |> add_call({m, f, length(args)}) |> atom_maker({m, f, length(args)}, args)
    scan(args, literal_mfa(m, f, args, acc))
  end

  defp scan({:call, _, {:remote, _, me, fe}, args}, acc) do
    site = {literal_atom(me), literal_atom(fe), length(args)}
    scan([me, fe | args], %{acc | dyn: [site | acc.dyn]})
  end

  defp scan({:call, _, {:atom, _, f}, args}, acc) do
    a = length(args)

    {m, _, _} =
      target = if MapSet.member?(acc.defined, {f, a}), do: {acc.m, f, a}, else: {:erlang, f, a}

    acc = acc |> add_call(target) |> atom_maker(target, args)
    scan(args, literal_mfa(m, f, args, acc))
  end

  defp scan({:fun, _, {:function, f, a}}, acc) when is_atom(f), do: add_call(acc, {acc.m, f, a})

  defp scan({:fun, _, {:function, {:atom, _, m}, {:atom, _, f}, {:integer, _, a}}}, acc),
    do: add_call(acc, {m, f, a})

  defp scan({:fun, _, {:function, me, fe, ae}}, acc) do
    a =
      case ae do
        {:integer, _, a} -> a
        _ -> nil
      end

    scan([me, fe, ae], %{acc | dyn: [{literal_atom(me), literal_atom(fe), a} | acc.dyn]})
  end

  defp scan({:atom, _, atom}, acc) do
    if MapSet.member?(acc.shipped, atom),
      do: %{acc | atoms: MapSet.put(acc.atoms, atom)},
      else: acc
  end

  defp scan(tuple, acc) when is_tuple(tuple), do: scan(Tuple.to_list(tuple), acc)
  defp scan([head | tail], acc), do: scan(tail, scan(head, acc))
  defp scan(_, acc), do: acc

  defp add_call(acc, mfa), do: %{acc | calls: [mfa | acc.calls]}

  defp literal_atom({:atom, _, atom}), do: atom
  defp literal_atom(_), do: nil

  # binary_to_atom(<<"Elixir.Dict">>) is an atom literal in disguise; Elixir
  # uses it to avoid compile-time dependencies.
  defp atom_maker(acc, mfa, args) when mfa in @atom_makers do
    case literal_text(List.first(args)) do
      nil -> %{acc | runtime_atoms: true}
      text -> scan({:atom, 0, String.to_atom(text)}, acc)
    end
  end

  defp atom_maker(acc, _mfa, _args), do: acc

  defp literal_text({:string, _, chars}), do: List.to_string(chars)

  defp literal_text({:bin, _, elements}) do
    parts =
      for {:bin_element, _, {:string, _, chars}, :default, :default} <- elements,
          do: List.to_string(chars)

    if length(parts) == length(elements), do: Enum.join(parts)
  end

  defp literal_text(_), do: nil

  @spawners [:apply, :spawn, :spawn_link, :spawn_monitor, :spawn_opt]

  defp literal_mfa(:erlang, f, args, acc) when f in @spawners do
    case args do
      [me, fe, list | _] ->
        case {literal_atom(me), literal_atom(fe), list_length(list)} do
          {m, f, n} when m != nil and f != nil and n != nil -> add_call(acc, {m, f, n})
          site -> %{acc | dyn: [site | acc.dyn]}
        end

      _ ->
        acc
    end
  end

  defp literal_mfa(_m, _f, _args, acc), do: acc

  defp list_length({nil, _}), do: 0

  defp list_length({:cons, _, _, tail}) do
    case list_length(tail) do
      nil -> nil
      n -> n + 1
    end
  end

  defp list_length(_), do: nil

  # ------------------------------------------------------------------ walk

  defp walk(index, roots) do
    loop(%{
      index: index,
      queue: roots,
      funs: MapSet.new(),
      atoms: MapSet.new(),
      dyn: MapSet.new(),
      wide_sites: [],
      runtime_atoms: []
    })
  end

  defp loop(%{queue: []} = state) do
    candidates = Enum.filter(state.atoms, &Map.has_key?(state.index.exports, &1))

    new =
      for {dm, f, a} <- state.dyn,
          dm != nil or (f != nil and a != nil),
          m <- if(dm, do: [dm], else: candidates),
          {ef, ea} <- Map.get(state.index.exports, m, []),
          (f == nil or ef == f) and (a == nil or ea == a),
          not MapSet.member?(state.funs, {m, ef, ea}),
          uniq: true,
          do: {m, ef, ea}

    if new == [], do: state, else: loop(%{state | queue: new})
  end

  defp loop(%{queue: [mfa | rest]} = state) do
    state = %{state | queue: rest}

    case Map.fetch(state.index.funs, mfa) do
      {:ok, info} ->
        if MapSet.member?(state.funs, mfa) do
          loop(state)
        else
          {m, _, _} = mfa
          wide? = Enum.any?(info.dyn, fn {dm, f, a} -> dm == nil and (f == nil or a == nil) end)

          loop(%{
            state
            | funs: MapSet.put(state.funs, mfa),
              atoms: MapSet.union(state.atoms, info.atoms),
              dyn: Enum.into(info.dyn, state.dyn),
              wide_sites: if(wide?, do: [mfa | state.wide_sites], else: state.wide_sites),
              runtime_atoms:
                if(info.runtime_atoms, do: [mfa | state.runtime_atoms], else: state.runtime_atoms),
              queue: info.calls ++ [{m, :module_info, 0}, {m, :module_info, 1} | state.queue]
          })
        end

      :error ->
        loop(state)
    end
  end

  defp kept_functions(funs) do
    funs
    |> Enum.group_by(fn {m, _, _} -> m end, fn {_, f, a} -> {f, a} end)
    |> Map.new(fn {m, fas} -> {m, MapSet.new([{:module_info, 0}, {:module_info, 1} | fas])} end)
  end

  # ------------------------------------------------------------------ build

  defp build({module, record, %{opaque?: true} = info, keep, false, cache}),
    do: build({module, record, info, keep, true, cache})

  defp build({module, record, _info, _keep, true, _cache}) do
    case strip(record.bytes) do
      {:ok, bytes} -> {:ok, module, bytes}
      :error -> {:error, module}
    end
  end

  defp build({module, record, info, keep, false, cache}) do
    key =
      {:build, @cache_version, :crypto.hash(:sha256, record.bytes),
       :erlang.phash2(Enum.sort(keep))}

    case cached(cache, key, fn -> rebuild(module, record.bytes, info, keep) end) do
      {:ok, bytes} -> {:ok, module, bytes}
      {:error, _} -> {:error, module}
    end
  end

  defp rebuild(module, bytes, info, keep) do
    {:ok, {^module, [debug_info: {:debug_info_v1, backend, data}]}} =
      :beam_lib.chunks(bytes, [:debug_info])

    {:ok, {^module, [compile_info: compile_info]}} = :beam_lib.chunks(bytes, [:compile_info])
    options = Keyword.get(compile_info, :options, [])

    if info.elixir? do
      rebuild_elixir(module, backend, data, options, info.defined, keep)
    else
      {:ok, forms} = backend.debug_info(:erlang_v1, module, data, [])
      rebuild_erlang(module, forms, options, keep)
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  # Elixir compiles from Core Erlang; rebuild the same way.
  defp rebuild_elixir(module, backend, data, options, defined, keep) do
    {:ok, core} = backend.debug_info(:core_v1, module, data, [])
    wanted? = fn fa -> MapSet.member?(keep, fa) or not MapSet.member?(defined, fa) end
    defs = for {name, _} = def <- :cerl.module_defs(core), wanted?.(:cerl.var_name(name)), do: def
    exports = for name <- :cerl.module_exports(core), wanted?.(:cerl.var_name(name)), do: name

    core =
      :cerl.update_c_module(
        core,
        :cerl.module_name(core),
        exports,
        :cerl.module_attrs(core),
        defs
      )

    options =
      Enum.flat_map(options, fn
        {:inline, fas} -> [{:inline, Enum.filter(List.wrap(fas), &MapSet.member?(keep, &1))}]
        option when option in [:debug_info, :report_errors, :report_warnings] -> []
        {:debug_info, _} -> []
        other -> [other]
      end)

    compile(module, core, [:binary, :return_errors, :deterministic | options])
  end

  defp rebuild_erlang(module, forms, options, keep) do
    forms =
      Enum.flat_map(forms, fn
        {:function, _, f, a, _} = form ->
          if MapSet.member?(keep, {f, a}), do: [form], else: []

        {:attribute, l, :export, fas} ->
          [{:attribute, l, :export, Enum.filter(fas, &MapSet.member?(keep, &1))}]

        {:attribute, _, :spec, {{f, a}, _}} = form ->
          if MapSet.member?(keep, {f, a}), do: [form], else: []

        {:attribute, _, :spec, {{_, f, a}, _}} = form ->
          if MapSet.member?(keep, {f, a}), do: [form], else: []

        {:attribute, l, :compile, opts} ->
          [{:attribute, l, :compile, compile_attribute(List.wrap(opts), keep)}]

        {:attribute, _, name, _} when name in [:deprecated, :unsafe, :dialyzer, :nifs] ->
          []

        other ->
          [other]
      end)

    options =
      Enum.reject(options, fn
        option when option in [:debug_info, :report_errors, :report_warnings, :verbose] ->
          true

        {key, _} when key in [:outdir, :i, :d, :debug_info_key, :parse_transform, :feature] ->
          true

        _ ->
          false
      end)

    compile(module, forms, [
      :binary,
      :return_errors,
      :deterministic,
      :nowarn_unused_function | options
    ])
  end

  defp compile_attribute(opts, keep) do
    Enum.flat_map(opts, fn
      {:inline, fas} -> [{:inline, Enum.filter(List.wrap(fas), &MapSet.member?(keep, &1))}]
      {:nowarn_unused_function, _} -> []
      other -> [other]
    end)
  end

  # The compiler records a placeholder Dbgi chunk even without debug_info.
  defp compile(module, input, options) do
    case :compile.forms(input, options) do
      {:ok, ^module, bytes} -> stripped(bytes)
      {:ok, ^module, bytes, _warnings} -> stripped(bytes)
      {:error, errors, _warnings} -> {:error, inspect(errors, limit: 5)}
    end
  end

  defp stripped(bytes) do
    case strip(bytes) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, "could not strip rebuilt BEAM"}
    end
  end

  @doc """
  Drops non-executable chunks (debug info, docs, Elixir type-check data) and
  writes the BEAM uncompressed; libbeam rejects `beam_lib:strip/1`'s gzip output.
  """
  def strip(bytes) do
    with {:ok, _module, chunks} <- :beam_lib.all_chunks(bytes),
         {:ok, stripped} <-
           :beam_lib.build_module(for {id, _} = chunk <- chunks, id in @kept_chunks, do: chunk) do
      {:ok, stripped}
    else
      _ -> :error
    end
  end

  # ------------------------------------------------------------------ check

  defp closure(rebuilt, shipped) do
    exports =
      Map.new(rebuilt, fn {module, bytes} ->
        {:ok, {^module, [exports: exports]}} = :beam_lib.chunks(bytes, [:exports])
        {module, MapSet.new(exports)}
      end)

    missing =
      for {module, bytes} <- rebuilt,
          {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(bytes, [:imports]),
          {tm, tf, ta} <- imports,
          MapSet.member?(shipped, tm),
          not MapSet.member?(Map.get(exports, tm, MapSet.new()), {tf, ta}),
          do: "#{module} imports #{tm}:#{tf}/#{ta}"

    case missing do
      [] ->
        :ok

      [first | _] ->
        {:error,
         "tree shaking left #{length(missing)} unresolved imports (#{first}); rebuild with --no-shake"}
    end
  end

  # ------------------------------------------------------------------ cache

  defp cached(false, _key, fun), do: fun.()

  defp cached(dir, key, fun) do
    path =
      Path.join(
        dir,
        Base.url_encode64(:crypto.hash(:sha256, :erlang.term_to_binary(key)), padding: false)
      )

    with {:ok, binary} <- File.read(path),
         {:ok, value} <- safe_decode(binary) do
      value
    else
      _ ->
        value = fun.()

        if match?({:ok, _}, value) do
          File.mkdir_p(dir)
          tmp = path <> ".#{System.unique_integer([:positive])}"
          with :ok <- File.write(tmp, :erlang.term_to_binary(value)), do: File.rename(tmp, path)
        end

        value
    end
  end

  defp safe_decode(binary) do
    {:ok, :erlang.binary_to_term(binary)}
  rescue
    _ -> :error
  end
end
