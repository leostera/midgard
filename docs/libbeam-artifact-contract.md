# Midgard → libbeam artifact contract (v1 and Gleam v2)

Status: **provisional build/handoff contract, not a libbeam runtime ABI**. The OTP checkout's [`Engine`/`Isolate` header](https://github.com/leostera/otp/blob/main/libbeam/include/libbeam/engine.hpp) now has a working **limited Erlang BEAM profile** for private loading and copied calls, but does not admit this Elixir worker/profile (maps, funs, broad OTP/Elixir modules). Midgard has no host adapter and has not called it. The artifact format is Midgard-owned and may change before a host consumes it. Passing static checks is not execution, sandboxing or libbeam compatibility.

## Responsibilities

- **Worker project + optional `midgard` SDK**: an Elixir worker may declare `handle_request(%Midgard.Request{}) :: {status, binary}` and receive a generated binary arity-one `__midgard_call__/1` bridge. Standalone Erlang or generic Mix workers may instead export their own binary arity-one function under an explicitly declared byte protocol. The typed SDK facade is provisional: today's libbeam core does not implement maps/structs and much of Elixir/OTP.
- **`packer`**: compile trusted Mix, single-app rebar3, or Erlang-target Gleam sources locally, select project and runtime dependency BEAMs in either Elixir or Erlang (including the SDK when used), reject obvious native inputs, and assemble exact-name BEAM files without loading or renaming them in a serving VM. Build tooling may use Mix/OTP; none of that authority is granted to future guests.
- **`midgard_cli`**: scaffold a project, read `midgard.config.exs`, select its worker/target profile and build artifacts. Packer exposes the separate `mix packer.inspect` command. `mix midgard.deploy` has been removed; a future deploy command requires an independently authorized host API.
- **Future host** (not implemented here): verify artifact bytes/manifest again; create an Isolate; call `load_module(ByteView)` for each admitted module; `start(module, declared_function, bytes)` and subsequent `call(...)` only after all modules are loaded; return bounded bytes; stop/reclaim the world. Host owns routing, deadlines and requested capability grants. No guest file paths, host PIDs, secrets or unconstrained terms cross the boundary. An Isolate derives a module's actual name from BEAM, never from the manifest's claim alone.

## On-disk format

The default output is `<app>.midgard/`, an **inspectable directory**. Files are `manifest.json` (UTF-8 JSON, version 1 for Mix/rebar3 or version 2 for Gleam) and `modules/<BEAM-module-name>.beam` (raw bytes). Paths are relative, regular files, never symlinks or external references. Sorted module and dependency arrays and stable manifest key order make identical inputs byte-identical. Build via a temporary sibling directory and replace the destination only after validation; never leave a half-valid artifact reported as successful. The caller can pass an explicit output directory. A file collection, not a runnable `.ex` or an Erlang term archive, is the handoff unit.

Manifest fields (types and meaning):

```json
{
  "format": "midgard.beam",
  "format_version": 1,
  "application": "hello_worker",
  "entrypoint": {
    "module": "Elixir.HelloWorker",
    "function": "__midgard_call__",
    "arity": 1,
    "protocol": "midgard.bytes.v1"
  },
  "compiler": {"otp_release": "28", "elixir_version": "1.19.5"},
  "target": {"runtime": "libbeam", "contract": "provisional-isolate-v1", "execution": "not_verified"},
  "dependencies": [
    {"app": "jason", "version": "1.4.5", "modules": ["Elixir.Jason"]}
  ],
  "modules": [
    {"name": "Elixir.HelloWorker", "owner": "hello_worker", "path": "modules/Elixir.HelloWorker.beam", "size": 1234, "sha256": "64 lowercase hex digits"}
  ],
  "required_capabilities": []
}
```

The abbreviated example shows only one module per owner; real manifests list **every** included BEAM once, with its verified name, byte count and checksum. The alphabetical order is for reproducibility, **not** a load plan: libbeam's current eager import resolution may reject unresolved or cyclic module graphs. `dependencies` records source app/version and exact owned module names. OTP/Elixir host-supplied imports are **not** silently considered available on libbeam: validation reports them as provisional requirements, and a future host must explicitly provide the positive-listed runtime profile. Format v1 records OTP/Elixir compiler versions for Mix/rebar3 projects. Format v2 retains the same exact-name BEAM, entrypoint, ownership, and target rules but records `compiler: {"otp_release": "...", "gleam_version": "..."}` for Gleam shipments, without claiming Elixir compiled Gleam code. Older consumers that understand only v1 must reject v2 rather than guessing. Compiler version fields do not imply that a different libbeam build can load the BEAM. No source is evaluated to inspect an artifact.

A structurally valid artifact has exact unique BEAM names, sorted file paths confined to `modules/`, an entrypoint module with its declared exported arity-one function, only known schema keys, checksums/sizes matching files, declared dependency ownership, and no unlisted files. Reject corruption, duplicates, unknown format versions, native/NIF references, explicit host-authority imports and missing callbacks. Be cautious about dynamic calls: static import scans cannot prove the absence of native effects. Parsing an artifact is **not** authorization to execute it.

## Static compatibility reports

Keep **structural verification** separate from **runtime-profile admission**:

- `valid_structure`: all file/manifest consistency checks pass on normal OTP without loading BEAMs. Failure rejects the artifact.
- `known_unsupported`: static evidence of incompatible operations/imports (for example native loading, direct filesystem or network access, maps/funs under the currently published additive core profile). Reject or explicitly mark blocked; never label executable.
- `unknown_or_future`: otherwise well-formed BEAMs which may require OTP/Elixir modules or libbeam instructions/BIFs not established by the current positive list. An artifact can be built and inspected, but **execution is not verified**. In particular, the typed `Midgard.Request` facade and Jason example belong here until the corresponding isolate profile exists.

Support a `--target current-core` diagnostic that rejects known unsupported bytecode/imports, and a default `provisional-isolate-v1` build that preserves unknowns as explicit diagnostics without pretending to pass current-core admission. This is a *static preflight*, not a libbeam loader. Prefer conservative failure over a false claim of compatibility; do not rely on a source text grep for NIF safety.

## SDK wire sketch

The SDK's `midgard.bytes.v1` protocol has a versioned frame tag, bounded field lengths, request method/path/query/headers/body and response status/body. A standalone raw Erlang entrypoint uses its explicitly declared `raw.bytes.v1` protocol instead; the two are not interchangeable. Response headers are deferred; this version supports complete bodies only. No Erlang term deserialization, streams, arbitrary host references or implicit services. Encoding/decoding must be bounded and testable entirely on ordinary OTP. A worker's generated wrapper takes/returns a binary; the byte frames are capped at libbeam's 64 KiB per-call/result transport bound. These are not heap, CPU or deadline guarantees. Worker-facing capability APIs remain unimplemented until there is a host broker and an enforceable grant model; `required_capabilities: []` is the only valid value in v1 and v2.

This proposal is informed by [the workerd/Workers comparison](workers-libbeam-comparison.md) and the current sibling checkout's [`two_isolates.md`](https://github.com/leostera/otp/blob/main/libbeam/examples/two_isolates.md). This Elixir artifact has not been loaded by libbeam. Running it, strict target-profile admission and secure multi-tenancy require further libbeam and host-adapter work outside this repository.
