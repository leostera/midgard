# Midgard — Elixir Workers artifact toolchain

Midgard scaffolds and compiles Elixir workers into **versioned, inspectable BEAM artifacts** for a future libbeam host adapter. It does not deploy them or execute them in libbeam. The separate [libbeam runtime](https://github.com/leostera/otp/tree/main/libbeam) can now run selected Erlang BEAMs in private Isolates, but **does not support the Elixir/OTP profile used by this example**. An artifact passing Midgard's static checks is not proof of runtime admission, isolation or production security.

## Try the toolchain (ordinary Elixir/OTP)

Requires Elixir 1.19 and OTP 27+ (`:json`; tested here on OTP 28). No Realm fork or Phoenix service is required.

```sh
mix test
cd examples/hello_worker
mix deps.get
mix test
mix midgard.build                   # hello_worker.midgard/
mix packer.inspect hello_worker.midgard
mix packer.inspect hello_worker.midgard --target current-core  # intentionally refuses unsupported Elixir features
```

`mix packer.pack` is the build-tool alternative using `packer: [entry: HelloWorker]` in `mix.exs`. Both commands compile under the developer's **trusted local authority**; they do not load the BEAMs into a serving VM. A generated project uses `midgard.config.exs` with `[entry: MyWorker, target: :libbeam]`. To scaffold outside the checkout, install the archive or invoke its task from here:

```sh
cd apps/midgard_cli
mix archive.build -o /tmp/midgard_cli.ez
mix archive.install --force /tmp/midgard_cli.ez
cd /path/where/you/work
mix midgard.new my_worker --midgard-root /path/to/midgard
cd my_worker && mix deps.get && mix test && mix midgard.build
```

Generated projects use **absolute path dependencies** into this checkout, not published packages. The generator refuses to overwrite an existing directory. `mix midgard.deploy` and the old Phoenix/Realm runtime were removed; there is no deployment endpoint or local Isolate runner.

## Components

- [`apps/midgard`](apps/midgard): worker-facing `Midgard.Worker` and `%Midgard.Request{}` plus `midgard.bytes.v1` bounded binary codec. `use Midgard.Worker` generates `__midgard_call__(binary) :: binary`. No packaging code or host capability bindings belong in the SDK. Request structs and this wrapper are **provisional** and are not currently supported by libbeam's reduced core.
- [`apps/packer`](apps/packer): builds `<app>.midgard/` from local compiled BEAMs and pure-Elixir dependency BEAMs, preserving each module's exact name. Its `manifest.json` records checksums, ownership, compiler versions, target assumptions, and an entrypoint. `mix packer.inspect` checks structure and reports known unsupported opcodes/imports and unresolved runtime requirements without loading the modules. Native inputs and direct ambient host authority are refused; **static screening is not a security proof**.
- [`apps/midgard_cli`](apps/midgard_cli): `mix midgard.new` and `mix midgard.build`. No host router, deployer, broker or Isolate caller exists.
- [`examples/hello_worker`](examples/hello_worker): two project modules plus a pure-Elixir Jason dependency, with real binary-wrapper unit tests on regular OTP.

Read the [artifact contract and compatibility limits](docs/libbeam-artifact-contract.md), [Packer usage](docs/packer.md), [request API](docs/worker-request-api.md), and [Workers/workerd/libbeam comparison](docs/workers-libbeam-comparison.md). [RFD0001](docs/rfds/RFD0001-elixir-edge-runtime-on-beam-realms.md) documents the superseded Realm experiment, not this implementation.

## Trust boundary

Packer's local Mix compilation can execute build scripts and macros **with the developer's host privileges**. Static BEAM validation rejects known direct host-authority imports, corrupt/unlisted files, untrusted paths and obvious native inputs, but cannot prove the absence of dynamic effects or certify an Isolate profile. The manifest explicitly says `"execution":"not_verified"`; no claimed OTP parity, NIF support, ambient filesystem/network access, capability broker, multi-tenancy guarantees, deployment security or libbeam execution follows from an artifact build. The future host must revalidate independently before any private BEAM loading and own all routing, timeouts and granted capabilities.
