# RFD0002 - Artifact and worker byte contract

- Feature Name: `midgard-artifact-and-worker-contract`
- Status: Implemented snapshot (build and inspection only)
- Author: Leandro Ostera
- Start Date: 2026-10-13

## Summary

Midgard compiles trusted local Mix, standalone rebar3 and Erlang-target Gleam projects into inspectable, versioned directories of **exact-name BEAMs**. Its artifact manifest names one binary arity-one entrypoint and records module ownership and compiler provenance. An optional Elixir SDK encodes bounded `midgard.bytes.v1` requests and responses. Packer verifies structure and reports static compatibility evidence, but neither builds nor inspection authorize execution. No libbeam host integration or deployment service is implemented here. This RFD describes the current repository contract; it does not propose a runtime.

## Motivation and scope

A host needs to know precisely which bytes and dependencies a worker requires without relying on the builder's VM code table or a guessed BEAM module name. A developer needs reproducible inspection before attempting admission. Mix, rebar3 and Gleam must be able to produce artifacts without pretending that their source languages share an SDK or that stock OTP behavior is supported by a different runtime.

This snapshot covers the build/inspect boundary, artifact schema and the existing **Elixir-only** worker API and byte codec. The first framework design effort is Elixir-focused; packaging Erlang and Gleam is not a commitment to copy Elixir's request structs, callback shape or dependencies into those languages. It does **not** specify HTTP hosting, deployment, hot upgrades, capability grants, Isolate lifecycle, or future language frameworks. User commands and prerequisites live in [the Packer guide](../packer.md).

## Guide-level model

A project supplies compiled BEAMs and a declared entrypoint. `mix packer.pack` (or `mix midgard.build` for a configured Mix worker) writes `<app>.midgard/`. `mix packer.inspect` checks what was written without loading it into a serving VM. Rebar3 and Gleam entrypoints may speak a declared application-owned byte protocol such as `raw.bytes.v1`; the Elixir SDK's generated `__midgard_call__/1` instead speaks `midgard.bytes.v1`. These protocols are **not** interchangeable. An artifact format version is not a wire protocol version. The artifact contract names a binary function, not a language-specific request type: future language APIs can be designed independently when needed.

The HelloWorker artifact can be built and structurally inspected while `--target current-core` reports blockers. That is the expected outcome, not a failed build or evidence that the worker ran in libbeam. A host consuming an artifact must verify it independently against its own tested runtime before loading the **complete** closure.

## Reference-level contract

### Ownership and build flow

- `apps/midgard` defines the Elixir request struct, codec and worker macro. The macro exports a binary arity-one wrapper around `handle_request/1`; the SDK itself is a runtime dependency when used.
- `apps/packer` compiles locally, gathers project and runtime dependency BEAMs and their application/version owners, writes a sibling staging directory, verifies it, then publishes it. The builder may run arbitrary **trusted** build scripts and macros with developer privileges. It does not load the packaged code in a serving VM.
- `apps/midgard_cli` scaffolds Mix workers and invokes the builder. It has no deploy command or Isolate caller.
- A future host is **outside this contract**. It must revalidate all bytes and imports, select a runtime profile, and own any routing, authority, deadlines, invocation and reclamation. A manifest's target or capability claim grants nothing.

Mix gathers its application and compiled runtime dependencies (including compiled `src/**/*.erl`); standalone rebar3 gathers one application's compiled `.app` files and dependencies; Gleam exports its production Erlang shipment and gathers `.app`-declared modules. Gleam's undeclared CLI launcher is excluded, **not** any declared dependency. Missing module files, duplicate module names, ambiguous ownership and native inputs cause failure rather than substitution, renaming or silent exclusion. OTP-provided modules are not silently bundled or promised by the artifact.

### On-disk artifact

An artifact contains exactly `manifest.json` and a `modules/` directory of `modules/<exact-BEAM-name>.beam` regular files. Files must not be symlinks. Each module record has `name`, `owner`, `path`, `size`, and lowercase SHA-256 `sha256`. Lists are sorted; each module belongs to exactly the local app or one declared dependency and the entrypoint belongs to the local app. Duplicate names or undeclared files are errors. The BEAM's internal module name must match the manifest and path. The builder caps artifacts at 512 modules, 2,000,000 bytes per BEAM, 32,000,000 BEAM bytes total, and 262,144 bytes for the manifest; these are tooling limits, not an Isolate resource policy.

The JSON manifest has exactly these top-level fields: `format` (`midgard.beam`), `format_version`, `application`, `entrypoint`, `compiler`, `target`, `dependencies`, `modules`, and `required_capabilities` (always `[]`). `entrypoint` holds `module`, `function`, `arity` (exactly 1), and a versioned `protocol`. `target` is exactly `{"runtime":"libbeam","contract":"provisional-isolate-v1","execution":"not_verified"}`. Each dependency records `app`, `version`, and its sorted module-name list.

| Format | Producer | Compiler provenance |
| --- | --- | --- |
| v1 | Mix or rebar3 | `otp_release`, `elixir_version` (the local tooling version, including for rebar3) |
| v2 | Erlang-target Gleam | `otp_release`, `gleam_version` |

Unknown formats or keys fail verification. Existing v1 artifacts retain their schema; v2 does **not** masquerade as Elixir-built code. Consumers that support only v1 must reject v2. Both formats retain the same BEAM identity, ownership, target and entrypoint rules. Manifest order is for reproducible bytes, **not a BEAM load order**; an eager runtime may reject imports or cycles regardless of sort order.

### Verification, static profile and failure

`Packer.Verifier` bounds and parses JSON, validates schema and file inventory, checks each file's size/hash/internal BEAM name, ownership and exported entrypoint, then rejects known direct host-authority imports and `on_load`. It uses OTP's BEAM tooling in a trusted local VM; it is **not** a hardened parser for adversarial uploads and does not establish NIF-freedom or absence of dynamic effects. The builder verifies the staging tree before publication, and a failed build does not intentionally replace the last verified artifact. Destinations cannot be symlinks.

`Packer.Profile` reports a pinned static snapshot: `known_unsupported_current_core`, `unresolved_imports`, `conditionally_supported_operations`, `profile_revision` and `execution: not_verified`. `--target current-core` refuses known blockers and unresolved imports. A zero-blocker result is a **preflight**, not an Isolate admission result. Dependencies and compiler support must be checked against the precise runtime build intended to execute them. Native/NIF loading, undeclared `priv/` resources, and host filesystem/network authority are not granted by packaging.

### Elixir `midgard.bytes.v1` wire

The codec accepts complete binary requests with uppercase ASCII method (1–16 bytes), slash-prefixed path (1–2048 bytes), raw query (up to 2048 bytes), up to 32 ordered lowercase header-name/value pairs (up to 8192 encoded header bytes, no CR/LF in values), and body (up to 32768 bytes). Duplicates are preserved. The entire frame is at most 65536 bytes. It does not parse URLs, JSON, cookies, or arbitrary Erlang terms.

The request frame is big-endian `<<1, method_len::8, path_len::16, query_len::16, header_count::8, body_len::16, method, path, query, headers, body>>`; each header is `<<name_len::8, value_len::16, name, value>>`. A response is `<<2, status::16, body_len::16, body>>` with status 100..599 and body at most 65531 bytes. Trailing bytes and malformed lengths are rejected. The generated Elixir wrapper responds with a bounded 400 for an invalid request frame and a bounded 500 for an invalid handler result or ordinary handler exception, **if the wrapper executes**. These are not host-side timeout, crash or isolation semantics. No custom response headers, streams, or capability handles cross the frame.

## Invariants and tradeoffs

- Preserve module identity and the complete declared runtime dependency group; never add synthetic aliases or drop a dependency just to pass static preflight.
- Keep the Elixir SDK at the guest-library boundary. The Packer schema and generic byte entrypoint do not depend on `%Midgard.Request{}` or `Midgard.Worker`; Erlang and Gleam may supply different application-level APIs later without an Elixir dependency.
- Validate untrusted artifact shape before treating it as an entrypoint or executing it; the present verifier is intended for trusted local inspection, so a real host must implement its own validation boundary.
- Do not mistake compiler provenance, a protocol label or an empty static diagnostics list for admission. `required_capabilities: []` is the only supported declaration in v1/v2; brokered capabilities need a separate contract.
- Reject native inputs and missing `priv/` resources rather than publishing an artifact whose apparent behavior depends on unshipped code. Dynamic calls and transitive effects remain limitations of static inspection.

The tradeoff is a deliberately limited artifact and byte API rather than transparent OTP, Fetch API parity, runtime compatibility promises, or bundled native services. Separate VMs and a future explicit host remain independent options; this artifact format does not choose a security boundary for them. Tests cover schema corruption, identity/ownership, rebuild preservation, per-origin packaging and the Elixir codec on ordinary OTP. Whole-group Isolate admission and response comparison remain separate runtime acceptance work, **not** accomplished by this RFD.
