# Releasing

All six packages share one version and are published together: `midgard`, `midgard_packer`, `midgard_cli`, `midgard_erlang`, `rebar3_midgard`, and `midgard_gleam`. Never publish a subset; the scaffold, SDKs, plugin, examples, and docs pin each other's versions.

`scripts/release.sh` runs the whole process. Each step refuses to run if an earlier one hasn't completed.

## Prerequisites

- Elixir, OTP 29, Rebar3 with the `rebar3_hex` plugin, Gleam, and Bun.
- Hex credentials for each tool: `mix hex.user auth` and `rebar3 hex user auth`. `gleam publish` asks for its own credentials, or reads `HEXPM_API_KEY`.
- If Mix reports `Unknown CA` or `token_refresh_unavailable`, export `HEX_CACERTS_PATH=/etc/ssl/cert.pem`. The script sets this by default.

## Release

```sh
scripts/release.sh bump 0.4.0      # 1. set the version everywhere
git diff                           #    review, then commit and push
scripts/release.sh check           # 2. every test suite + build all six tarballs
scripts/release.sh publish --dry-run
scripts/release.sh publish         # 3. publish all six to Hex
scripts/release.sh finalize        # 4. point examples at Hex, commit, push
scripts/release.sh smoke           # 5. run the website quickstarts against Hex
scripts/release.sh deploy-site     # 6. deploy and verify midgard.leostera.dev
```

After `bump` and a commit, `scripts/release.sh all` runs steps 2–6 in order.

### 1. `bump VERSION`

Rewrites the version in every package manifest, in the scaffold's `~> MAJOR.MINOR` requirements, and in the tests, docs, website, and example configs that pin it. It then points the Gleam example at the local SDK so unreleased SDK changes are tested before publishing, and lists any remaining mentions of the old version for you to review.

### 2. `check`

Runs the Elixir umbrella tests, the Erlang SDK and example EUnit suites, the Rebar3 plugin compile, the Gleam builds and format checks, and the website tests, typecheck, and build. Then it builds all six Hex tarballs without publishing them, and confirms each declares the release version and ships its README.

### 3. `publish [--dry-run]`

Requires a clean, pushed working tree, the same version in all six packages, and Hex sign-ins for Mix and Rebar3. It publishes the SDKs before the tools that scaffold projects depending on them, then waits until Hex lists all six. Packages already published at this version are skipped, so after a failure you can fix the problem and rerun it. `--dry-run` runs the pre-flight checks and prints what would be published.

Packages are published without HexDocs, as in earlier releases; the READMEs link to GitHub.

### 4. `finalize`

Points the Gleam example at the published `midgard_gleam`, relocks the Erlang example against Hex (its `_checkouts` development symlinks are moved aside while Rebar3 writes the lock, then restored), reruns the Packer tests, and commits and pushes the result.

### 5. `smoke [elixir] [gleam] [erlang]`

Runs `scripts/smoke-test-quickstarts.sh`. It follows the website quickstarts in throwaway directories with a fresh `MIX_HOME`, installs everything from Hex, deploys each worker to the public demo, and checks that `GET /` returns `Hello Joe!`. The Elixir quickstart uses the pinned Elixir from `/tmp/midgard-toolchain` (or `MIDGARD_ELIXIR_TOOLCHAIN`), and builds it if it's missing.

### 6. `deploy-site`

The website shows the new install commands, so this refuses to run until all six packages are live. It deploys the site and checks that the live bundle shows the new version.
