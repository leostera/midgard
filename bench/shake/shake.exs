# Prototype for RFD0003: function-level tree shaking of a Midgard artifact.
#
#   elixir bench/shake/shake.exs SRC.midgard DST.midgard
#
# Exploratory, not Packer code. Recovers each module's Erlang abstract code,
# walks the function graph from the manifest entrypoint, rewrites every module
# with only reachable functions, recompiles without debug info, and writes a
# new artifact plus a JSON report next to it.
#
# Dynamic dispatch rules (see RFD0003 for the evidence behind each):
# - A module value can only come from an atom literal in reachable code, so a
#   call with a computed module and known f/a reaches f/a in every module named
#   by a reachable atom. Protocol dispatch and exception callbacks fall out of
#   this rule. binary_to_atom/list_to_atom of a literal counts as that atom.
# - A literal module with a computed function keeps that module's exports of
#   that arity.
# - Calls with neither a module nor a function name known are reported, not
#   widened (SHAKE_MODE=sound widens them and keeps nearly everything).
# Iterates to a fixpoint. Elixir modules are rebuilt from their core_v1 debug
# info with their own compile options; Erlang modules from abstract code.

defmodule Shake do
  def main([src, dst]) do
    t0 = now()
    manifest = src |> Path.join("manifest.json") |> File.read!() |> :json.decode()
    entry = manifest["entrypoint"]
    root = {String.to_atom(entry["module"]), String.to_atom(entry["function"]), entry["arity"]}

    modules =
      for record <- manifest["modules"], into: %{} do
        name = String.to_atom(record["name"])
        bin = File.read!(Path.join(src, record["path"]))
        {name, %{bin: bin, record: record}}
      end

    shipped = Map.keys(modules) |> MapSet.new()
    {index, t_index} = timed(fn -> index(modules, shipped) end)
    # Extra roots: functions the runtime calls itself, e.g. SHAKE_ROOTS=elixir:start/2
    # when the host starts the :elixir application before the entrypoint.
    extra =
      for target <- String.split(System.get_env("SHAKE_ROOTS", ""), ",", trim: true) do
        [m, fa] = String.split(target, ":")
        [f, a] = String.split(fa, "/")
        {String.to_atom(m), String.to_atom(f), String.to_integer(a)}
      end
    {reach, t_walk} = timed(fn -> walk(index, [root | extra]) end)
    if System.get_env("SHAKE_WALK_ONLY") do
      mods = reach.funs |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      IO.puts("walk: #{MapSet.size(reach.funs)} functions in #{length(mods)} modules")
      IO.puts("wide sites (#{length(reach.wide_sites)}): " <> (reach.wide_sites |> Enum.map(&mfa/1) |> Enum.sort() |> Enum.join(" ")))
      IO.puts("atom makers (#{length(reach.dynamic_atoms)}): " <> (reach.dynamic_atoms |> Enum.map(&mfa/1) |> Enum.sort() |> Enum.join(" ")))
      for target <- String.split(System.get_env("SHAKE_WHY", ""), ",", trim: true) do
        [m, fa] = String.split(target, ":")
        [f, a] = String.split(fa, "/")
        IO.puts("\nwhy #{target}:")
        why(reach.parent, {String.to_atom(m), String.to_atom(f), String.to_integer(a)}, 0)
      end
      System.halt(0)
    end
    {rewritten, t_compile} = timed(fn -> rewrite(index, reach) end)
    problems = closure_problems(rewritten, shipped)
    write_artifact(manifest, rewritten, dst)

    total_before = modules |> Map.values() |> Enum.map(&byte_size(&1.bin)) |> Enum.sum()
    total_after = rewritten |> Map.values() |> Enum.map(&byte_size/1) |> Enum.sum()

    report = %{
      modules: %{before: map_size(modules), after: map_size(rewritten)},
      functions: %{before: map_size(index.funs), after: MapSet.size(reach.funs)},
      bytes: %{before: total_before, after: total_after},
      ms: %{index: t_index, walk: t_walk, compile: t_compile, total: now() - t0},
      unresolved_imports: problems,
      dynamic_atom_sites: reach.dynamic_atoms |> Enum.map(&mfa/1) |> Enum.sort(),
      unknown_function_sites: reach.wide_sites |> Enum.map(&mfa/1) |> Enum.sort(),
      kept_modules: rewritten |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
    }

    File.write!(dst <> ".report.json", :json.encode(report))
    IO.puts("""
    modules    #{report.modules.before} -> #{report.modules.after}
    functions  #{report.functions.before} -> #{report.functions.after}
    bytes      #{total_before} -> #{total_after}
    time       index #{t_index}ms, walk #{t_walk}ms, compile #{t_compile}ms, total #{report.ms.total}ms
    unresolved imports: #{length(problems)}
    reachable functions that create atoms at runtime: #{length(report.dynamic_atom_sites)}
    reachable calls with an unknown function name or arity: #{length(report.unknown_function_sites)}
    report: #{dst}.report.json
    """)
  end

  # SHAKE_MODE=sound widens calls with unknown function names (keeps almost
  # everything); the default "known" mode resolves only known f/a and reports
  # the rest, relying on keep lists and verification.
  defp wide_mode?, do: System.get_env("SHAKE_MODE") == "sound"

  defp now, do: System.monotonic_time(:millisecond)
  defp timed(fun) do
    t = now()
    result = fun.()
    {result, now() - t}
  end

  defp mfa({m, f, a}), do: "#{m}:#{f}/#{a}"

  defp why(_parent, nil, _), do: :ok
  defp why(_parent, _, depth) when depth > 40, do: IO.puts("  ...")
  defp why(parent, {:dynamic, site}, depth) do
    IO.puts("  (dynamic call in) #{if site, do: mfa(site), else: "?"}")
    why(parent, site, depth + 1)
  end
  defp why(parent, mfa, depth) do
    IO.puts("  " <> mfa(mfa))
    why(parent, Map.get(parent, mfa), depth + 1)
  end

  # ---------------------------------------------------------------- index

  defp index(modules, shipped) do
    per_module =
      modules
      |> Task.async_stream(fn {name, %{bin: bin}} -> {name, index_module(name, bin, shipped)} end,
        timeout: :infinity, ordered: false)
      |> Map.new(fn {:ok, pair} -> pair end)

    funs =
      for {_m, info} <- per_module, {key, fun_info} <- info.funs, into: %{}, do: {key, fun_info}

    exports =
      for {m, info} <- per_module, into: %{}, do: {m, MapSet.new(info.exports)}

    %{modules: per_module, funs: funs, exports: exports, shipped: shipped}
  end

  defp index_module(name, bin, shipped) do
    {:ok, {^name, [debug_info: {:debug_info_v1, backend, data}]}} = :beam_lib.chunks(bin, [:debug_info])
    {:ok, forms} = backend.debug_info(:erlang_v1, name, data, [])
    {:ok, {^name, [compile_info: info]}} = :beam_lib.chunks(bin, [:compile_info])
    exports = for {:attribute, _, :export, list} <- forms, fa <- list, do: fa
    defined = for {:function, _, f, a, _} <- forms, into: MapSet.new(), do: {f, a}

    funs =
      for {:function, _, f, a, clauses} = form <- forms, into: %{} do
        acc = scan(clauses, %{m: name, defined: defined, shipped: shipped,
          calls: [], dyn: [], atoms: MapSet.new(), dynamic_atoms: false})
        {{name, f, a}, %{form: form, calls: acc.calls, dyn: acc.dyn, atoms: acc.atoms, dynamic_atoms: acc.dynamic_atoms}}
      end

    behaviours = for {:attribute, _, kind, b} <- forms, kind in [:behaviour, :behavior], do: b
    callbacks = for {:attribute, _, :callback, {{f, a}, _}} <- forms, do: {f, a}
    %{forms: forms, exports: exports, funs: funs, options: Keyword.get(info, :options, []),
      behaviours: behaviours, callbacks: callbacks,
      elixir?: backend == :elixir_erl, backend: backend, data: data, defined: defined}
  end

  @atom_makers [{:erlang, :binary_to_atom, 1}, {:erlang, :binary_to_atom, 2},
                {:erlang, :list_to_atom, 1}, {:erlang, :binary_to_existing_atom, 1},
                {:erlang, :binary_to_existing_atom, 2}, {:erlang, :list_to_existing_atom, 1}]

  # Generic walk over abstract code, recording edges.
  defp scan({:call, _, {:remote, _, {:atom, _, m}, {:atom, _, f}}, args} = _call, acc) do
    a = length(args)
    acc = add_call(acc, {m, f, a})
    acc = if {m, f, a} in @atom_makers, do: atom_from_literal(args, acc), else: acc
    acc = literal_mfa_args(m, f, args, acc)
    scan(args, acc)
  end

  defp scan({:call, _, {:remote, _, me, fe}, args}, acc) do
    m = case me do {:atom, _, m} -> m; _ -> nil end
    f = case fe do {:atom, _, f} -> f; _ -> nil end
    acc = %{acc | dyn: [{m, f, length(args)} | acc.dyn]}
    scan([me, fe | args], acc)
  end

  defp scan({:call, _, {:atom, _, f}, args}, acc) do
    a = length(args)
    target = if MapSet.member?(acc.defined, {f, a}), do: {acc.m, f, a}, else: {:erlang, f, a}
    acc = add_call(acc, target)
    acc = if target in @atom_makers, do: atom_from_literal(args, acc), else: acc
    {m, f2, _} = target
    acc = literal_mfa_args(m, f2, args, acc)
    scan(args, acc)
  end

  defp scan({:fun, _, {:function, f, a}}, acc) when is_atom(f), do: add_call(acc, {acc.m, f, a})
  defp scan({:fun, _, {:function, {:atom, _, m}, {:atom, _, f}, {:integer, _, a}}}, acc), do: add_call(acc, {m, f, a})
  defp scan({:fun, _, {:function, me, fe, ae}}, acc) do
    f = case fe do {:atom, _, f} -> f; _ -> nil end
    a = case ae do {:integer, _, a} -> a; _ -> nil end
    m = case me do {:atom, _, m} -> m; _ -> nil end
    scan([me, fe, ae], %{acc | dyn: [{m, f, a} | acc.dyn]})
  end

  defp scan({:atom, _, x}, acc) do
    if MapSet.member?(acc.shipped, x), do: %{acc | atoms: MapSet.put(acc.atoms, x)}, else: acc
  end

  defp scan(tuple, acc) when is_tuple(tuple), do: scan(Tuple.to_list(tuple), acc)
  defp scan([h | t], acc), do: scan(t, scan(h, acc))
  defp scan(_, acc), do: acc

  # binary_to_atom(<<"Elixir.Dict">>) and friends with a literal argument are
  # an atom literal in disguise (Elixir uses this to avoid compile-time
  # dependencies). Anything else really creates atoms at runtime.
  defp atom_from_literal([arg | _], acc) do
    case literal_text(arg) do
      nil -> %{acc | dynamic_atoms: true}
      text ->
        atom = String.to_atom(text)
        if MapSet.member?(acc.shipped, atom), do: %{acc | atoms: MapSet.put(acc.atoms, atom)}, else: acc
    end
  end

  defp literal_text({:string, _, chars}), do: List.to_string(chars)
  defp literal_text({:bin, _, elements}) do
    parts = for {:bin_element, _, {:string, _, chars}, :default, :default} <- elements, do: List.to_string(chars)
    if length(parts) == length(elements), do: Enum.join(parts), else: nil
  end
  defp literal_text(_), do: nil

  defp add_call(acc, mfa), do: %{acc | calls: [mfa | acc.calls]}

  # erlang:apply/3, spawn/3 and similar with literal module, function and
  # argument list: an exact edge. Otherwise apply is a dynamic site.
  defp literal_mfa_args(m, f, args, acc) when (m == :erlang and f in [:apply, :spawn, :spawn_link, :spawn_monitor, :spawn_opt]) do
    case args do
      [{:atom, _, tm}, {:atom, _, tf}, list | _] ->
        case list_length(list) do
          nil -> %{acc | dyn: [{tm, tf, nil} | acc.dyn]}
          n -> add_call(acc, {tm, tf, n})
        end
      [{:atom, _, tm}, _, list | _] -> %{acc | dyn: [{tm, nil, list_length(list)} | acc.dyn]}
      [_, {:atom, _, tf}, list | _] -> %{acc | dyn: [{nil, tf, list_length(list)} | acc.dyn]}
      [_, _, list | _] -> %{acc | dyn: [{nil, nil, list_length(list)} | acc.dyn]}
      _ -> acc
    end
  end

  defp literal_mfa_args(_m, _f, _args, acc), do: acc

  defp list_length({nil, _}), do: 0
  defp list_length({:cons, _, _, tail}) do
    case list_length(tail) do
      nil -> nil
      n -> n + 1
    end
  end
  defp list_length(_), do: nil

  # ---------------------------------------------------------------- walk

  defp walk(index, roots) do
    state = %{funs: MapSet.new(), atoms: MapSet.new(), dyn: MapSet.new(), dynamic_atoms: [], wide_sites: [], queue: Enum.map(roots, &{&1, nil}), index: index, parent: %{}, dyn_from: %{}}
    loop(state)
  end

  defp loop(%{queue: [], index: index} = state) do
    # Resolve dynamic sites against the reachable atom set; repeat to a fixpoint.
    candidates = Enum.filter(state.atoms, &Map.has_key?(index.exports, &1))
    # A literal module limits the targets to that module, whatever f/a is.
    new =
      for {dm, f, a} = site <- state.dyn,
          m <- if(dm, do: [dm], else: candidates), Map.has_key?(index.exports, m),
          {ef, ea} <- index.exports[m],
          (f == nil or ef == f) and (a == nil or ea == a),
          dm != nil or wide_mode?() or (f != nil and a != nil),
          not MapSet.member?(state.funs, {m, ef, ea}), uniq: true,
          do: {{m, ef, ea}, {:dynamic, Map.get(state.dyn_from, site)}}
    # Behaviour callbacks: OTP behaviours call Mod:init/1 and friends through
    # proc_lib/apply with computed names. If a referenced module declares
    # -behaviour(B) and code in B is reachable, its callbacks for B are too.
    reached = state.funs |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    callbacks =
      for m <- candidates, System.get_env("SHAKE_BEHAVIOURS") == "1",
          b <- index.modules[m].behaviours, MapSet.member?(reached, b),
          Map.has_key?(index.modules, b), {f, a} <- index.modules[b].callbacks,
          MapSet.member?(index.exports[m], {f, a}), not MapSet.member?(state.funs, {m, f, a}),
          uniq: true, do: {{m, f, a}, {:dynamic, {b, :behaviour, 0}}}
    new = new ++ callbacks
    if new == [], do: state, else: loop(%{state | queue: new})
  end

  defp loop(%{queue: [{mfa, from} | rest]} = state) do
    state = %{state | queue: rest}
    cond do
      MapSet.member?(state.funs, mfa) -> loop(state)
      not Map.has_key?(state.index.funs, mfa) -> loop(state)
      true ->
        info = state.index.funs[mfa]
        {m, _, _} = mfa
        wide = Enum.any?(info.dyn, fn {m, f, a} -> m == nil and (f == nil or a == nil) end)
        state = %{state |
          parent: Map.put(state.parent, mfa, from),
          dyn_from: Enum.reduce(info.dyn, state.dyn_from, &Map.put_new(&2, &1, mfa)),
          funs: MapSet.put(state.funs, mfa),
          atoms: MapSet.union(state.atoms, info.atoms),
          dyn: Enum.into(info.dyn, state.dyn),
          dynamic_atoms: if(info.dynamic_atoms, do: [mfa | state.dynamic_atoms], else: state.dynamic_atoms),
          wide_sites: if(wide, do: [mfa | state.wide_sites], else: state.wide_sites),
          queue: Enum.map(info.calls ++ [{m, :module_info, 0}, {m, :module_info, 1}], &{&1, mfa}) ++ state.queue
        }
        loop(state)
    end
  end

  # ---------------------------------------------------------------- rewrite

  defp rewrite(index, reach) do
    kept_by_module =
      Enum.group_by(reach.funs, fn {m, _, _} -> m end, fn {_, f, a} -> {f, a} end)
      |> Map.new(fn {m, fas} -> {m, MapSet.new(fas)} end)

    # Each task receives only its own module: a closure over the whole index
    # would copy every module's abstract code into every task.
    kept_by_module
    |> Enum.map(fn {m, keep} -> {m, index.modules[m], keep} end)
    |> Task.async_stream(fn {m, info, keep} ->
      {t, bin} = :timer.tc(fn -> compile(m, info, keep) end)
      {m, bin, div(t, 1000)}
    end, timeout: :infinity, ordered: false, max_concurrency: String.to_integer(System.get_env("SHAKE_JOBS", "#{System.schedulers_online()}")))
    |> Enum.map(fn {:ok, triple} -> triple end)
    |> tap(fn results ->
      slow = results |> Enum.sort_by(&elem(&1, 2), :desc) |> Enum.take(8) |> Enum.map(fn {m, _, ms} -> "#{m} #{ms}ms" end)
      IO.puts("slowest recompiles: " <> Enum.join(slow, ", "))
    end)
    |> Map.new(fn {m, bin, _} -> {m, bin} end)
    |> Map.reject(fn {_, bin} -> bin == nil end)
  end

  # Elixir compiles from Core Erlang; rebuild from its core_v1 debug info with
  # the module's own options, so kept functions follow Elixir's compile path.
  defp compile(m, %{elixir?: true} = info, keep) do
    keep = MapSet.union(keep, MapSet.new([{:module_info, 0}, {:module_info, 1}]))
    {:ok, core} = info.backend.debug_info(:core_v1, m, info.data, [])
    wanted? = fn fa -> MapSet.member?(keep, fa) or not MapSet.member?(info.defined, fa) end
    defs = for {name, _} = def <- :cerl.module_defs(core), wanted?.(:cerl.var_name(name)), do: def
    exports = for name <- :cerl.module_exports(core), wanted?.(:cerl.var_name(name)), do: name
    core = :cerl.update_c_module(core, :cerl.module_name(core), exports, :cerl.module_attrs(core), defs)
    opts =
      Enum.flat_map(info.options, fn
        {:inline, fas} -> [{:inline, Enum.filter(fas, &MapSet.member?(keep, &1))}]
        other -> [other]
      end)
    case :compile.forms(core, [:binary, :return_errors, :deterministic | opts]) do
      {:ok, ^m, bin} -> bin
      {:ok, ^m, bin, _warnings} -> bin
      {:error, errors, _} ->
        IO.puts(:stderr, "could not recompile #{m}: #{inspect(errors, limit: :infinity, printable_limit: 500) |> String.slice(0, 600)}")
        nil
    end
  end

  defp compile(m, info, keep) do
    keep = MapSet.union(keep, MapSet.new([{:module_info, 0}, {:module_info, 1}]))
    forms =
      Enum.flat_map(info.forms, fn
        {:function, _, f, a, _} = form -> if MapSet.member?(keep, {f, a}), do: [form], else: []
        {:attribute, l, :export, fas} -> [{:attribute, l, :export, Enum.filter(fas, &MapSet.member?(keep, &1))}]
        {:attribute, _, :spec, {{f, a}, _}} = form -> if MapSet.member?(keep, {f, a}), do: [form], else: []
        {:attribute, _, :spec, {{_, f, a}, _}} = form -> if MapSet.member?(keep, {f, a}), do: [form], else: []
        {:attribute, l, :compile, opts} -> [{:attribute, l, :compile, filter_compile(List.wrap(opts), keep)}]
        {:attribute, _, :deprecated, _} -> []
        {:attribute, _, :unsafe, _} -> []
        {:attribute, _, :dialyzer, _} -> []
        {:attribute, _, :nifs, _} -> []
        other -> [other]
      end)

    base = Enum.reject(info.options, fn
      o when o in [:debug_info, :report_errors, :report_warnings, :verbose] -> true
      {k, _} when k in [:outdir, :i, :d, :debug_info_key, :parse_transform, :feature] -> true
      _ -> false
    end)
    extra = if info.elixir?, do: [:no_auto_import], else: []
    opts = [:binary, :return_errors, :deterministic, :no_spawn_compiler_process, :nowarn_unused_function] ++ extra ++ base

    case :compile.forms(forms, opts) do
      {:ok, ^m, bin} -> bin
      {:ok, ^m, bin, _warnings} -> bin
      {:error, errors, _} ->
        IO.puts(:stderr, "could not recompile #{m}: #{inspect(errors, limit: :infinity, printable_limit: 500) |> String.slice(0, 600)}")
        nil
    end
  end

  defp filter_compile(opts, keep) do
    Enum.flat_map(opts, fn
      {:inline, fas} -> [{:inline, Enum.filter(List.wrap(fas), &MapSet.member?(keep, &1))}]
      {:nowarn_unused_function, _} -> []
      other -> [other]
    end)
  end

  # ---------------------------------------------------------------- check + write

  defp closure_problems(rewritten, shipped) do
    exports =
      for {m, bin} <- rewritten, into: %{} do
        {:ok, {^m, [exports: e]}} = :beam_lib.chunks(bin, [:exports])
        {m, MapSet.new(e)}
      end

    for {m, bin} <- rewritten,
        {:ok, {^m, [imports: imports]}} = :beam_lib.chunks(bin, [:imports]),
        {tm, tf, ta} <- imports,
        MapSet.member?(shipped, tm),
        not (Map.has_key?(exports, tm) and MapSet.member?(exports[tm], {tf, ta})),
        do: "#{m} imports #{tm}:#{tf}/#{ta}"
  end

  defp write_artifact(manifest, rewritten, dst) do
    File.rm_rf!(dst)
    File.mkdir_p!(Path.join(dst, "modules"))
    records =
      for record <- manifest["modules"], bin = rewritten[String.to_atom(record["name"])], bin != nil do
        File.write!(Path.join(dst, record["path"]), bin)
        %{record | "size" => byte_size(bin), "sha256" => Base.encode16(:crypto.hash(:sha256, bin), case: :lower)}
      end
    kept = MapSet.new(records, & &1["name"])
    deps =
      for dep <- manifest["dependencies"],
          mods = Enum.filter(dep["modules"], &MapSet.member?(kept, &1)),
          mods != [], do: %{dep | "modules" => mods}
    out = %{manifest | "modules" => records, "dependencies" => deps}
    File.write!(Path.join(dst, "manifest.json"), :json.encode(out))
  end
end

Shake.main(System.argv())
