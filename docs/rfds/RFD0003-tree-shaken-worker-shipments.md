# RFD0003 - Tree-shaken worker shipments

- Feature Name: `midgard-tree-shaking`
- Status: Draft
- Author: Leandro Ostera
- Start Date: 2026-10-21

## Summary

Packer should ship only the code a worker can actually run. Starting from the manifest's entrypoint, it walks the **function-level** call graph of the worker and every module in its closure, including OTP and the Elixir standard library. It then rewrites each surviving module from its abstract code with every unreachable function removed, and drops modules with nothing reachable. Because unreachable functions take their imports with them, the result is a smaller closure that still satisfies libbeam's whole-group rule that every import resolves. A hello-world Elixir worker should go from 339 modules and 18 MB to roughly 77–228 modules and under 2–5 MB, and its deploy from ~86 seconds to a few seconds. Packer also stops shipping debug info, docs, and Elixir type-check chunks. This amends RFD0002's invariant that the complete declared dependency group ships unchanged: modules keep their exact names, but their bytes may differ from the compiler's output, and the manifest records that.

## Motivation

Gleam and Erlang workers deploy in about 4 seconds. A freshly scaffolded Elixir worker takes 75–90 seconds, which is the first thing someone trying Midgard experiences.

Measured with `scripts/measure-deploy.sh` and a replayed upload against the public demo on 2026-10-21:

| Shipment of the generated `elixir_worker` | Modules | Upload | Upload time | Server time after upload | Result |
| --- | --- | --- | --- | --- | --- |
| As built today | 339 | 18.0 MB | 19.0 s | 66.6 s | admitted |
| Without `Dbgi`, `Docs`, `ExCk` chunks | 339 | 7.0 MB | 6.1 s | 36.9 s | admitted, serves correctly |
| Plus static function-level reachability (modules only) | 77 | 1.8 MB | 1.9 s | 4.9 s | **rejected**: unresolved import |
| Gleam `gleam_worker`, for comparison | 2 | 12 KB | – | – | ~1.9 s total |

The worker's own code is 7 modules. The other 332 are Elixir, `stdlib`, `kernel`, `compiler`, `erts`, `iex`, and `logger`, shipped because Packer includes the whole declared runtime closure (RFD0002). Most of those bytes are never executed:

- Of 17.9 MB, 8.9 MB is debug info, 1.1 MB docs, and 1.0 MB Elixir type-check data. Executable code is 4.1 MB.
- From `Elixir.ElixirWorker.__midgard_call__/1`, only **907 of 26,251 functions** are statically reachable, spread over 77 modules. Conservatively allowing for dynamic dispatch still leaves only about 14,000 functions in 228 modules.

Two facts block a simple fix:

1. **Module-level shaking does not work.** The BEAM module graph is densely connected through rarely taken paths. `Enum` reaches `ArgumentError`, then `elixir_erl_pass`, then `compile`. `Kernel` reaches `Module`, `elixir`, then `iex`. `IO` reaches `io`, `net_kernel`, `inet_config`, then `win32reg`. Following only real imports keeps 336 of 339 modules.
2. **libbeam admits a shipment as a whole and requires every import to resolve.** Dropping modules that no reachable function calls still fails, because unreachable functions in kept modules import them. The 77-module experiment was rejected for `Elixir.Enum.OutOfBoundsError:exception/1`, which `Enum` imports for an error path the worker never takes.

So the only way to drop what a worker doesn't use, without changing the runtime's admission rule, is to remove unreachable **functions** from modules, and therefore their imports.

## Goals

- Ship only reachable code for Mix, Rebar3, and Gleam workers, through the whole closure including OTP and Elixir.
- Produce shipments libbeam admits under its current whole-group import rule.
- Never remove code a worker can execute. When reachability cannot be decided, keep the code and say why.
- Make the result explainable: why a function was kept, and what was dropped.
- Keep builds reproducible: the same inputs produce the same bytes.

## Non-goals

- Changing libbeam's admission rules. Lazy, unresolved imports are a separate, complementary proposal (see Alternatives).
- Optimizing kept code (inlining, constant folding). Kept functions are recompiled, not optimized beyond what the compiler already does.
- Making untrusted code safe. Shaking is a size optimization on trusted local builds, not a security boundary.
- Shaking NIF-backed or `on_load` modules. Packer already rejects them.

## Guide-level explanation

Shaking is on by default once stable; a flag turns it off:

```sh
mix midgard.deploy               # shaken
mix packer.pack --no-shake       # the full closure, as before
rebar3 midgard pack              # shaken
mix packer.pack --project . --gleam ...   # shaken
```

Packer reports what it did (numbers illustrative):

```text
Packed elixir_worker.midgard
  shaken: 339 → 81 modules, 26,251 → 1,094 functions, 17.9 MB → 1.4 MB
Static current-core profile: 0 known unsupported, 0 unresolved imports; execution NOT VERIFIED
```

Code reached only dynamically, for example through `apply/3` with a computed module, is kept when Packer can see the candidates, such as atoms that name modules in the same function. When it can't, the build fails rather than guessing:

```text
** (Mix) Packer cannot decide what MyWorker.dispatch/2 calls:
   apply(mod, :run, [request]) with a module computed at runtime.
   Keep the possible targets explicitly:
     packer: [keep: [MyWorker.Jobs.Email, {MyWorker.Jobs.Sms, :run, 1}]]
```

A worker can ask why something is in its shipment:

```sh
$ mix packer.inspect elixir_worker.midgard --why Elixir.Inspect.Algebra
Elixir.ElixirWorker.__midgard_call__/1
  → Elixir.Midgard.Worker.call/2
  → Elixir.Kernel.inspect/2
  → Elixir.Inspect.Algebra.format/2
```

Tests run against the shaken shipment too. `mix packer.verify` loads the shaken modules into a separate, ordinary OTP node and runs the worker's tests there, so a function that was dropped but is actually needed fails locally with `undef`, not in production.

## Reference-level explanation

### Pipeline

Shaking runs inside Packer after collecting the closure and before writing the artifact:

1. **Collect.** Same as today: the project's and every runtime dependency's compiled BEAMs and owners (RFD0002).
2. **Index.** For each module, recover its Erlang abstract code from its `Dbgi` chunk through the module's debug-info backend (`erl_abstract_code` for Erlang, `elixir_erl` for Elixir). Build a function table: for each `{M, F, A}`, its outgoing edges.
3. **Seed roots.** See [Roots](#roots).
4. **Walk.** Mark every function reachable from the roots, following the [edge rules](#edges). Unknown dynamic calls are a build error unless covered by `keep`.
5. **Rewrite.** For each module with at least one reachable function, drop unreachable function definitions and their `export` entries, then recompile the forms with the compiler options recorded in the module's `CInf`, plus `deterministic` and without `debug_info`. Drop modules with no reachable function.
6. **Strip.** Keep only the chunks libbeam and the verifier need: `AtU8`, `Code`, `StrT`, `ImpT`, `ExpT`, `FunT`, `LitT`, `LocT`, `Attr`, `CInf`, `Line`, `Type`. Write the BEAM **uncompressed** with `beam_lib:build_module/1`; libbeam rejects the gzip output of `beam_lib:strip/1`.
7. **Verify.** Run the existing verifier and static profile, plus a closure check: every import of every kept module resolves to a kept export. This catches walker bugs before upload.

Steps 2 and 5 dominate build time. Rewritten modules are cached by `{original sha256, kept function set, compiler version}`, so `stdlib` and Elixir are shaken once per toolchain and worker shape, not on every build.

### Roots

- The manifest entrypoint, for example `Elixir.ElixirWorker.__midgard_call__/1` or `gleam_worker:handle/1`.
- `module_info/0` and `module_info/1` of every kept module, which the runtime requires.
- Functions the runtime itself may call: `error_handler:undefined_function/3` and similar. The precise list is set by what libbeam calls, see [Unresolved questions](#unresolved-questions).
- Everything named in `keep`.

### Edges

A function's edges are found from its abstract code:

- **Local and remote calls** with literal targets: `f(...)`, `m:f(...)`.
- **Function references**: `fun f/1`, `fun m:f/1`, and fun literals in constants.
- **Behaviour callbacks.** If a kept module declares `-behaviour(B)` and code calls into `B` (for example `gen_server`), its callbacks for `B` are reachable.
- **Elixir protocols.** A call to a consolidated protocol function reaches `impl_for/1`, whose literal module atoms name the implementations. Each implementation's function of the same name and arity is reachable. Unconsolidated protocols are an error. Mix consolidates protocols at compile time by default outside the test environment.
- **Elixir exceptions.** `raise SomeError, ...` reaches `SomeError.exception/1` and `message/1`, which `Kernel` and `Exception` call dynamically.
- **Structs.** `%S{}` reaches `S.__struct__/0,1`.
- **`apply/2,3`, `erlang:apply`, and `Mod:fun(...)` with a computed module.** If every candidate is visible, the edges go to each candidate's function with that name and arity. Candidates are atoms that name modules in the same function, or values flowing from a local function that returns only literals, as `impl_for/1` does. Otherwise this is an **undecidable dynamic call**: the build fails and names the call site, unless `keep` covers it.
- **Calls with a computed function name** (`apply(M, fun_name, args)`) keep all exports of `M` of that arity.

These rules are deliberately conservative: they may keep code that never runs, but never drop code that can. Measured on the hello world, static calls alone reach 907 functions, and treating every module-naming atom in dynamically dispatching functions as a candidate reaches about 14,000. The rules above should land much closer to the first number. Validating that is the first implementation milestone.

### Configuration

| Tool | Setting |
| --- | --- |
| Mix | `packer: [shake: true, keep: [Mod, {Mod, :fun, arity}]]` in `mix.exs`, or `midgard.config.exs` |
| Rebar3 | `{midgard, [{shake, true}, {keep, [mod, {mod, fun, Arity}]}]}` |
| Gleam | `--shake` / `--no-shake` and repeated `--keep module.fun/arity` flags |

`keep: [Mod]` keeps every export of `Mod`.

### Artifact format

Shaken artifacts use `format_version` 3. It is v1 (Mix, Rebar3) or v2 (Gleam) plus:

- each module record gains `original_sha256`, the hash of the compiler's BEAM before shaking. `sha256` and `size` describe the shipped bytes;
- a top-level `shaking` object: `{"mode": "function", "roots": [...], "kept": ["Mod.fun/1", ...], "functions": {"before": 26251, "after": 1094}, "dropped_modules": [...]}`.

`dependencies[].modules` lists only kept modules. A dependency with no kept modules is listed with `modules: []` so its version is still recorded.

The platform's shipment verifier (`apps/midgard_platform/lib/midgard/platform/shipment.ex`) must accept v3 before Packer emits it by default; until then shaking is opt-in. Unshaken artifacts remain v1/v2 and are unaffected.

### Invariants

This amends RFD0002's "preserve … the complete declared runtime dependency group" as follows:

- A kept module keeps its exact name and internal module name. Packer never renames or aliases.
- Every function reachable from the roots is present with the same behaviour as the compiler's original output. Shaking removes functions; it never changes a kept function's code.
- Every import of every kept module resolves within the shipment.
- When reachability cannot be decided, the build fails or the code is kept. It never silently drops.
- The manifest records the original hash of every rewritten module, so a shipment is traceable to the compiler's output.
- `--no-shake` produces exactly today's artifact.

### Failure semantics

- **Missing abstract code:** a module without recoverable abstract code is kept whole. Its imports still have to resolve, so its callees are kept whole too. Packer reports which module caused it.
- **Undecidable dynamic call:** the build fails with the call site and a suggested `keep` entry.
- **Recompile failure:** the build fails naming the module. This indicates a Packer bug; `--no-shake` is the workaround.
- **Closure check failure:** the build fails before writing the artifact.
- **Behaviour drift:** if a dropped function turns out to be needed at runtime, the worker raises `undef` in libbeam. `mix packer.verify` exists to catch this locally, and the `--why` and manifest data make it diagnosable.

### Observable differences for worker code

Removing functions also removes exports. Code that introspects exports sees the shaken module: `function_exported?/3`, `Module.__info__(:functions)`, `module_info(exports)`, and `Code.ensure_loaded?` followed by an optional call. Elixir and OTP use this pattern for optional callbacks, for example `GenServer` checking whether `format_status/1` is defined. The walker treats each `function_exported?(M, F, A)` call with literal arguments as an edge to `M:F/A`, so the answer doesn't change. A computed `function_exported?` is an undecidable dynamic call.

## Drawbacks

- **Large and subtle.** The walker must model Erlang and Elixir dynamic dispatch correctly, and mistakes surface as runtime `undef` in production. This is the main risk, mitigated by failing builds on undecidable calls, the closure check, and running the tests against the shaken modules.
- **Shipped bytes no longer match the compiler's.** Debugging a shipped module means comparing against `original_sha256`. Stack traces still work because `Line` is kept.
- **Slower cold builds.** Recovering abstract code and recompiling dozens of stdlib modules costs seconds on the first build per toolchain, mitigated by the cache.
- **More configuration.** Projects that dispatch dynamically must maintain `keep` lists.
- **A new artifact version** that the platform must learn before shaking becomes the default.

## Rationale and alternatives

### Proposed design

Function-level shaking with module rewriting is the only option that removes unused code without changing libbeam's admission rule. It works for all three languages because they all compile to BEAM with abstract code available at build time (all 339 modules of the measured closure have it). It also makes each shipment's contents explainable, which matters as much as size for a platform that admits whole groups.

### Simpler or narrower approach

**Only strip non-executable chunks.** This alone halves the Elixir deploy (85.7 s → 43.0 s) with no semantic risk, so it ships first, independently of this RFD's acceptance. It does not address the 339-module closure or the per-module admission cost, which is still about 37 s.

### Other alternatives considered

- **Module-level shaking.** Simple and semantically safe, but measured useless: real imports alone reach 336 of 339 modules.
- **Lazy unresolved imports in libbeam.** Let libbeam admit modules whose imports don't resolve, raising `undef` if called, as the regular BEAM does with lazy loading. Packer could then drop whole modules after a function-level walk, without rewriting anything: about 77–228 modules for the hello world. It is simpler on the Packer side, but changes a runtime admission guarantee and still ships every unreachable function inside kept modules. It is complementary rather than competing: if libbeam gains it, Packer can skip rewriting modules that contain no unreachable imports.
- **Rewriting at the BEAM assembly level** (`beam_disasm` to `beam_asm`) instead of abstract code. It works without debug info, but is fragile across OTP releases and not a supported compiler interface. Abstract code is.
- **Trimming known-unneeded OTP applications** (`compiler`, `iex`, `logger`) by hand. Fast, but brittle, incomplete, and still blocked by imports from kept modules.
- **A precompiled, shared runtime in the platform.** The host could preload one copy of Elixir and OTP for all workers, so shipments contain only application code. This removes the problem for the standard library but ties worker builds to the host's exact toolchain, which RFD0002 deliberately avoids, and it does nothing for large third-party dependencies.

### Do nothing

Elixir workers stay roughly 20 times slower to deploy than Erlang and Gleam workers. The cost grows with every dependency, because every module in a dependency ships and is admitted whether or not it's used.

## Prior art

- **JavaScript bundlers** (Rollup, esbuild, webpack): tree shaking over static ES module imports, falling back to keeping everything for dynamic `import()`. The lesson: be conservative around dynamic access, and expose why code was included.
- **ProGuard and R8** for the JVM: whole-program shrinking with explicit `-keep` rules for reflection, which is the model for `keep` here. Their main failure mode, missing keep rules for reflection, motivates failing the build on undecidable calls instead of guessing.
- **GraalVM native-image**: closed-world reachability analysis with reflection configuration, and an agent that records dynamic accesses at runtime. A future Midgard equivalent could record `apply` targets during tests.
- **Elixir protocol consolidation and `mix release`** already rely on a closed world at build time. Consolidated protocols are what make protocol dispatch decidable here.
- **Erlang `reltool`** strips debug info and selects applications for releases, but at application and module granularity only.

## Unresolved questions

### Before acceptance

- Should an undecidable dynamic call fail the build (proposed) or keep all candidates with a warning?
- Which functions does libbeam itself call, and therefore must always be roots (error handler, exit and exception paths)?
- Should shaking become the default for all languages at once, or Elixir first, where the gain is largest?

### During implementation

- The exact recompile options per backend, and whether recompiling Elixir modules from `elixir_erl` abstract code yields byte-identical functions for kept code.
- Cache location and invalidation across OTP and Elixir upgrades.
- How `mix packer.verify` runs worker tests against shaken modules for Rebar3 and Gleam projects.
- Whether to keep the `Type` chunk.

### Out of scope

- Lazy unresolved imports in libbeam.
- Shrinking within functions (dead branches, unused clauses).
- Recording dynamic-call targets at runtime to suggest `keep` entries.

## Future possibilities

- Share shaken standard-library modules across workers on the host by `sha256`, so common code is uploaded and admitted once.
- Show a shipment's composition (what's kept and why) on the worker's detail page.
- Use the reachability index to warn about calls into code libbeam doesn't support before deploying.
