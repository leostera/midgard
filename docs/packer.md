# Packer — versioned BEAM artifacts

From a worker project with `packer: [entry: HelloWorker]` in `mix.exs`, run `mix deps.get && mix packer.pack`. Generic Packer projects may override its binary arity-one entrypoint with `--function NAME --protocol ID`; this does not import the worker SDK. Or set `[entry: HelloWorker, target: :libbeam]` in `midgard.config.exs` and run `mix midgard.build` for the Midgard protocol. Both write `<app>.midgard/` by default (`--output DIR` overrides it). `mix packer.inspect DIR` verifies and prints static compatibility diagnostics. `mix packer.inspect DIR --target current-core` fails if known unsupported bytecode/imports or unresolved imports remain; even an empty report **cannot establish execution** on a libbeam build.

```
<app>.midgard/
  manifest.json
  modules/Elixir.HelloWorker.beam
  modules/Elixir.HelloWorker.Greeter.beam
  modules/Elixir.Jason.beam
  ...
```

The [manifest contract](libbeam-artifact-contract.md) specifies `format_version: 1`, exact entrypoint, dependency ownership and versions, compiler OTP/Elixir versions, sorted BEAM identities, file lengths and SHA-256 hashes. Every module is included with its original BEAM name; there are no source snippets, encoded comment modules, module renames or global *serving-VM* code-table writes. The on-disk directory is assembled and verified in a temporary sibling before publication. Rebuilds of identical compiled inputs produce byte-identical manifests. Packer does not deploy or invoke libbeam.

**What runs with host authority:** Mix compilation and dependency resolution, including macros, build tasks and dev/test compilation, occur in your normal local OTP instance. Use only trusted sources. Packer rejects direct imports of host filesystem/network/process-control APIs, `:erlang.load_nif` and `@on_load`, and obvious native/Erlang dependency inputs. This conservative scan is not a sandbox: dynamic calls, compile-time behavior and transitive OTP effects are not proven absent. No dependency `priv` resources, runtime app startup or config are included; development-only (`runtime: false`) dependencies are omitted. The Midgard SDK itself is packaged as a runtime dependency, **not** assumed to be host-provided.

**What inspection proves:** the JSON schema, version, file list, no symlinked files, checksums, BEAM internal names, owned dependency module list and exported binary entrypoint agree; it has not loaded or executed modules. Inspection uses OTP's BEAM parser in the *trusted local tooling VM* (which may intern names): it is not a hardened verifier for adversarial uploads. The report identifies known unsupported current-core instructions such as maps/funs and imports of unavailable services; `unresolved_imports` includes OTP/Elixir modules or BIFs that require a separately defined host runtime profile. This is not a complete whitelist of libbeam instructions, not a positive admission result, and not a proof of NIF-freedom. The example's Jason and `%Midgard.Request{}` dependencies produce a structurally valid **but currently unsupported** libbeam target profile.

See the [Workers/workerd comparison](workers-libbeam-comparison.md) for the future host boundary. A host must verify module identities and imports *again*, select a supported compiler/profile, load exact-name BEAM bytes privately, and grant explicit capabilities before any execution; Midgard currently implements no such host.
