# RFD0003 - Tree-shaken worker shipments

- Feature Name: `midgard-tree-shaking`
- Status: Implemented in Packer 0.4.0 (Elixir workers)
- Author: Leandro Ostera
- Start Date: 2026-10-21
- Updated: 2026-10-21

## Summary

Packer should ship only the functions a worker can reach. It walks the function-level call graph from the manifest entrypoint through the whole closure, including Elixir and OTP, rebuilds every module with unreachable functions removed, and drops modules with nothing reachable. A prototype (`bench/shake/`) did this for the generated Elixir worker: **339 modules and 17.9 MB became 103 modules and 1.1 MB, libbeam admitted it, and the deploy went from 85.7 s to 6.1 s** with identical responses. On ordinary OTP, a worker exercising `inspect`, `Enum` over maps and sets, interpolation, `URI` and exception messages answered all nine test routes identically to the unshaken worker.

The exploration also found a bug in today's Packer, independent of shaking: it does not ship Elixir protocol implementations, so `Enum` over a map, `"#{123}"` and `inspect/1` of most terms cannot work on Midgard. Fixing it is the first step of this RFD.

Shaking changes RFD0002's rule that the complete dependency group ships unchanged: modules keep their exact names, but their bytes change, and the manifest records that.

## Motivation

Erlang and Gleam workers deploy in about 10 s, end to end. A freshly generated Elixir worker takes about 85 s (`scripts/measure-deploy.sh`, three runs, October 2026). That is the first thing an Elixir developer sees, and the landing page leads with "Serverless Elixir".

The cost is the shipment. Packer ships the worker's whole runtime closure (RFD0002): for a hello world, all of Elixir, `stdlib`, `kernel`, `compiler`, `erts`, `iex` and `logger`, 339 modules and 17.9 MB, of which the worker's own code is 7 modules. Uploading takes about 19 s; libbeam admitting 339 modules takes about 67 s. Every stored Elixir worker is also re-admitted whenever the platform container restarts, so the cost recurs.

Most of it is never executed:

- 8.9 MB is debug info, 1.1 MB docs and 1.0 MB Elixir type-check data. Executable code is 4.1 MB.
- From `Elixir.ElixirWorker.__midgard_call__/1`, about 1,460 of 22,366 functions are reachable under the rules below.

Two constraints rule out simpler fixes:

1. **Dropping whole modules does not work.** The module graph is densely connected through rarely taken paths, and following real imports keeps 336 of 339 modules.
2. **libbeam admits a shipment as a whole and requires every import to resolve.** A 77-module experiment that dropped modules but kept their contents was rejected: `Enum` imports `Enum.OutOfBoundsError.exception/1` for an error path the worker never takes.

Only removing unreachable **functions**, and with them their imports, shrinks the closure while still satisfying libbeam.

## Goals

- Ship only reachable code for Elixir workers, through the whole closure, admitted by libbeam's current whole-group import rule.
- Make Elixir deploys comparable to Erlang and Gleam: a few seconds and a few MB.
- Keep packing fast: shaking must not add more time than it saves.
- Make the result explainable (why a function was kept) and verifiable before deploying.
- Keep builds reproducible.

## Non-goals

- Changing libbeam's admission rules (lazy imports are an alternative, below).
- Optimizing kept code, or shrinking within functions.
- Making untrusted code safe. Shaking is a size optimization on trusted local builds.
- Shaking workers that start OTP applications or processes. That needs more roots than the entrypoint; see [Runtime roots](#runtime-roots).

## What the prototype established

All numbers are from `bench/shake/shake.exs` on the generated `elixir_worker` (hello world) and a `stress_worker` that exercises `inspect` of maps, ranges, structs and MapSets, `Enum` over maps, ranges and MapSets, string interpolation, `String`, `URI`, rescued exceptions and an uncaught raise.

### 1. Rebuilding modules works, but Elixir must be rebuilt from Core Erlang

All 339 modules in the closure have recoverable abstract code. Erlang modules recompile from their Erlang abstract code with their recorded options, minus include paths and `debug_info`. Elixir modules do not: Elixir now compiles from Core Erlang (`from_core`, `no_core_prepare`), so recompiling its Erlang abstract code with its own options crashes `core_lint`, and recompiling it without them takes a different compiler path than Elixir does. Elixir's debug-info backend can produce Core Erlang (`elixir_erl:debug_info(core_v1, ...)`), and rebuilding from that with the module's own options works for every Elixir module in the closure.

Attributes that name functions must be filtered with the functions: `export`, `spec`, `inline`, `deprecated`, `unsafe`, `dialyzer`, `nifs`. A few modules still fail to recompile (`erl_lint` and `crypto` when reached with extra roots); a failed module must be kept whole, not dropped.

### 2. A fully safe analysis keeps almost everything

Treating every call whose function name or arity is unknown as able to reach any export of any candidate module keeps 20,693 functions in 330 modules. The hello world reaches the Elixir compiler through an error path:

```text
ElixirWorker.__midgard_call__/1 → Enum.reverse/1 → Enumerable.impl_for!/1
  → Protocol.UndefinedError.exception/1 → Kernel.struct!/2
  → elixir_erl_pass:parens_map_field/2 → IO.warn_once/3 → ... → Kernel.inspect/1
  → Inspect.Map.inspect_as_map/2 → elixir_erl_pass:no_parens_remote/2
  → (Map:Key() with a computed function) → every export, incl. elixir_compiler:bootstrap/0
```

A handful of such calls on error and formatting paths decide the whole result. Safety at those sites has to come from verification, not from the walk.

### 3. "Known target" rules are enough in practice

The prototype resolves dynamic calls only when their target is narrowed by a literal:

| Pattern | Rule |
| --- | --- |
| `m:f(...)`, `f(...)`, `fun m:f/a` | static edge (an unknown local `f` is the auto-imported BIF `erlang:f`) |
| `apply(m, f, [a1, ..., an])`, `spawn*` with literals | static edge to `m:f/n` |
| `Mod:f(...)` with computed `Mod`, known `f/a` | `f/a` in every module named by a **reachable atom** |
| `m:Fun(...)` with literal `m`, computed `Fun` | all exports of `m` with that arity |
| `binary_to_atom(<<"Elixir.Dict">>)` and friends with a literal | that atom (Elixir uses this to avoid compile-time dependencies) |
| neither module nor function known | reported, not followed |

A module value can only come from an atom in reachable code, so the reachable-atom rule covers protocol dispatch (`impl_for/1` names its implementations), `exception.__struct__.message/1`, and struct callbacks, without special cases. Results:

| Worker | Modules | Functions | Bytes | Unknown-target sites | Runtime atom creation sites |
| --- | --- | --- | --- | --- | --- |
| `elixir_worker` | 339 → 103 | 22,366 → 1,463 | 17.9 MB → 1.09 MB | 2 | 6 |
| `stress_worker` | 344 → 111 | 22,585 → 1,586 | 18.1 MB → 1.14 MB | 2 | 6 |
| `stress_worker` + protocol impls | 406 → 181 | 22,848 → 3,533 | 18.4 MB → 1.51 MB | 2 | 13 |

The two unknown-target sites in every case are `ErlangError.error_info/3` and `elixir_erl_pass:no_parens_remote/2`, both in error formatting. Every shaken shipment had zero unresolved imports.

### 4. Packer does not ship protocol implementations today

`Packer.RuntimeClosure` follows imports and external fun references. A consolidated protocol names its implementations only as atoms in `impl_for/1`, so they are never shipped. The stress worker's closure contains 1 of 12 `Enumerable` implementations (`List`), 5 of 32 `Inspect`, 1 of 12 `String.Chars`, and no `Collectable` or `List.Chars`. On the live platform, the unshaken stress worker returns 500/502 for `inspect`, `Enum` over a map, interpolation, `URI` and exception messages. Those failures had been attributed to libbeam; at least part of them is this bug. Erlang and Gleam workers are unaffected because they do not use protocols.

Adding every implementation from Elixir's `ebin` to the unshaken shipment makes libbeam reject it (`Collectable.HashDict` imports `HashDict`, which is not shipped). Shaking resolves this: only implementations reachable through dispatched functions are kept, and their imports come with them.

### 5. Verified behaviour

- **libbeam:** the shaken hello world was admitted in 6.1 s (upload and admission; 85.7 s unshaken) and answered `/`, `/hello/joe`, a Unicode name, `/hello/`, a query string, `/nope` and a `POST` byte-for-byte like the unshaken worker.
- **OTP 29:** `bench/shake/swap.erl` boots `:elixir` from its real modules, then hot-loads the shaken Elixir, SDK and worker modules over them, so all later calls run shaken code. With protocol implementations in the closure, all nine stress routes matched the unshaken worker exactly. With Packer's current closure, `/inspect`, `/enum` and `/uri` failed, which is how finding 4 surfaced.
- **Not yet verified:** the shaken stress worker with protocol implementations on libbeam. Its upload coincided with the platform container restarting, and the upload was not retried. See [Unresolved questions](#unresolved-questions).

### 6. Runtime roots change everything

The entrypoint is the only root libbeam needs: it calls the entrypoint and nothing else. Adding `elixir:start/2`, which an OTP node calls when it starts `:elixir`, grows the stress worker from 111 to 228 modules and still does not boot. Supervisors start children from data such as `{elixir_config, start_link, []}`, and behaviours call callbacks through `proc_lib` with computed names. Workers that start applications or processes need two more rules, behaviour callbacks and MFA tuples in literals, and get much smaller wins.

### 7. Packing time

| Phase | Prototype, uncached |
| --- | --- |
| Read debug info and index 339 modules | 2–10 s |
| Walk | 0.5–1.5 s |
| Rebuild ~100 modules in parallel | 2–12 s |
| Total | 4.5–25 s, typically ~9 s (12-core laptop, noisy) |

A first implementation passed the whole index into every compile task and took 75–128 s; giving each task only its own module brought the rebuild phase down to 2 s. Indexing and rebuilding the standard library depend only on the toolchain and the kept function set, so they cache well across workers and builds.

## Implementation status

Implemented in `Packer.Shake` and `Packer.RuntimeClosure` (Packer 0.4.0), and used by `mix midgard.build` and `mix midgard.deploy` by default. Differences from the design below:

- **Artifact format stays v1.** Shaken modules are still exact-name BEAMs with correct sizes and hashes, so the existing schema and the live platform accept them unchanged. `original_sha256` and the `shaking` manifest object are deferred; the build prints the shaking summary instead.
- **Opaque modules.** A module without debug info is kept whole (stripped), and any reachable export of it reaches all of its imports and module atoms.
- **`mix packer.verify` is not implemented yet.** `apps/packer/test/shake_test.exs` runs the same check in a `:peer` node: it shakes a real Elixir closure, loads the shaken modules over a booted `:elixir`, and compares results with the originals.
- **Rebar3 and Gleam are unchanged.** Their shipments are already small.

Measured with the implementation on the generated Elixir worker: 414 → 177 modules (the closure now includes protocol implementations) and 18.8 MB → 1.5 MB; libbeam admitted it in 8.3 s, and its responses matched. A stress worker with protocol implementations, uploaded once more deliberately, was admitted in 9.5 s without the platform restarting; its `inspect`, `Enum` over maps, interpolation, `String` and `URI` routes still fail on libbeam, as they do unshaken, so those are libbeam gaps rather than shipment problems.

## Guide-level explanation

Shaking is on by default for Elixir once stable:

```sh
mix midgard.deploy            # shaken
mix packer.pack --no-shake    # the full closure, as before
```

```text
Packed elixir_worker.midgard
  shaken: 339 → 103 modules, 22,366 → 1,463 functions, 17.9 MB → 1.1 MB (1.8 s, cached)
  2 calls with unknown targets kept as-is (error formatting); see --why
```

A worker that dispatches dynamically to its own modules lists them:

```elixir
# mix.exs
packer: [keep: [MyWorker.Jobs.Email, {MyWorker.Jobs.Sms, :run, 1}]]
```

Packer explains its choices and checks them before deploying:

```sh
mix packer.inspect elixir_worker.midgard --why Elixir.Inspect.Map
mix packer.verify                # run the worker's tests against the shaken modules on OTP
```

## Reference-level explanation

### Pipeline

1. **Collect** the closure as today, **including the implementations of every consolidated protocol in it** (from `__protocol__(:impls)`), so that dispatch targets are available to the walk.
2. **Index** every module: recover Erlang abstract code from `Dbgi`; for each function, record static edges, dynamic sites, and atom literals that name shipped modules.
3. **Walk** from the roots with the rules in finding 3, to a fixpoint. Roots: the manifest entrypoint, `module_info/0,1` of every kept module, and `keep` entries.
4. **Rewrite** each module with reachable functions: Elixir modules from `core_v1` with their recorded options, Erlang modules from abstract code with their recorded options; filter function-naming attributes; compile with `deterministic` and without `debug_info`. If a module fails to rebuild, keep it whole and walk all of its functions.
5. **Strip** non-executable chunks; write BEAMs uncompressed (libbeam rejects `beam_lib:strip/1`'s gzip output).
6. **Check closure:** every import of a kept module resolves to a kept export or to a module outside the shipment (runtime BIFs). Fail the build otherwise.
7. **Report:** unknown-target sites and runtime atom creation sites, with the path that reached them.

Steps 2 and 4 are cached by `{toolchain, module sha256}` and `{module sha256, kept function set}`.

### Unknown-target sites

Failing the build on every unknown-target site would fail every Elixir build: the two error-formatting sites above are always present. The proposal: report them, fail only for sites in the project's own modules unless covered by `keep`, and rely on `mix packer.verify` for the standard library.

### Runtime roots

Roots are a property of the host. libbeam calls only the entrypoint, which is what makes the results above possible. If a future host starts OTP applications, it must declare its extra roots (for example `elixir:start/2`), and the walk must add behaviour callbacks for referenced modules and treat literal `{M, F, Args}` tuples as edges.

### Artifact format

Shaken artifacts use `format_version` 3: v1 plus, per module, `original_sha256` (the compiler's bytes) and a top-level `shaking` object (`roots`, function counts, dropped modules, unknown-target sites). The platform's shipment verifier (`apps/midgard_platform/lib/midgard/platform/shipment.ex`) must accept v3 before shaking becomes the default. Unshaken artifacts are unchanged.

### Invariants

- Kept modules keep their exact names; nothing is renamed or aliased.
- Every kept function has the same behaviour as the compiler's output; shaking only removes functions.
- Every import of every kept module resolves within the shipment or to the runtime.
- A module that fails to rebuild is kept whole, never dropped.
- `--no-shake` produces today's artifact.

### Observable differences

Removing functions removes exports. `function_exported?/3`, `module_info(:exports)` and `__info__(:functions)` see the shaken module. Literal `function_exported?(M, F, A)` calls are edges, so their answer does not change; computed ones are unknown-target sites.

## Implementation plan

1. **Ship protocol implementations** in `Packer.RuntimeClosure` (finding 4). This fixes today's Elixir workers regardless of shaking, but grows unshaken shipments and needs libbeam to accept their imports, so it may need to land together with step 3.
2. **Strip non-executable chunks** (no rewriting): measured 85.7 s → 43 s for the hello world.
3. **Shake behind `--shake`**, artifact v3, platform support, report and `--why`.
4. **`mix packer.verify`**, built on the hot-swap harness.
5. **Cache** the index and rebuilt modules; target a warm pack under 5 s.
6. **Default on** for Elixir once verify passes on the examples.

## Drawbacks

- The walk must model dynamic dispatch correctly. Misses surface as `undef` at runtime; the closure check, the report and `packer.verify` are the mitigations. The prototype missed one pattern (`binary_to_atom` of a literal) before verification caught it.
- Shipped bytes no longer match the compiler's; `original_sha256` keeps them traceable.
- Rebuilding from Core Erlang depends on Elixir's `core_v1` debug-info backend and its compile options, which may change between Elixir versions.
- A new artifact version.

## Rationale and alternatives

- **Strip chunks only.** Halves the deploy with no semantic risk and ships first, but leaves 339 modules to upload and admit.
- **Drop whole modules.** Measured useless: 336 of 339 modules remain.
- **Lazy unresolved imports in libbeam.** Admit modules whose imports do not resolve and raise `undef` if called. Packer could then drop modules without rewriting them, but kept modules would still carry all their unreachable functions, and a runtime guarantee would weaken. Complementary, not a replacement.
- **Rewrite at the BEAM assembly level.** Works without debug info, but is not a supported compiler interface.
- **A shared, preloaded standard library on the host.** Shipments would contain only application code, but worker builds would be tied to the host's exact toolchain, and third-party dependencies would still ship whole.
- **Do nothing.** Elixir deploys stay around 85 s, grow with every dependency, and keep failing on protocol dispatch.

## Prior art

- **JavaScript bundlers** (Rollup, esbuild): tree shaking over static imports, conservative around dynamic access, and the ability to explain inclusions.
- **ProGuard and R8:** whole-program shrinking with `-keep` rules for reflection; the model for `keep`.
- **GraalVM native-image:** closed-world analysis plus recorded reflection configuration; a future `packer.verify` could record dynamic targets the same way.
- **Elixir protocol consolidation and `mix release`:** consolidation is what makes protocol dispatch decidable here.
- **`reltool`:** strips debug info and selects applications, at application and module granularity only.

## Unresolved questions

### Before acceptance

- Why did the platform container restart during the shaken stress upload? A single upload taking down every worker is a platform bug, whatever the cause.
- Does libbeam run the shaken stress worker's `inspect`, `Enum` and `URI` paths once protocol implementations are shipped? This separates the Packer bug from real libbeam gaps.
- Should shipping protocol implementations (step 1) land before shaking or together with it?

### During implementation

- The policy for unknown-target sites in project code.
- Cache location and invalidation.
- How `packer.verify` drives a worker's tests, and how it applies to Rebar3 and Gleam.

### Out of scope

- Lazy imports in libbeam; hosts that start OTP applications; shrinking within functions.

## Future possibilities

- Share shaken standard-library modules across workers by `sha256`, so common code is uploaded and admitted once.
- Show a shipment's composition on the worker's detail page.
- Use the reachability index to warn about calls into code libbeam doesn't support before deploying.
