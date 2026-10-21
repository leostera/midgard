# Releasing

All six packages share one version and are published together: `midgard`, `midgard_packer`, `midgard_cli`, `midgard_erlang`, `midgard_gleam`, and `rebar3_midgard`. Never publish a subset; the scaffold, SDKs, plugin, and docs pin each other's versions.

## 1. Pre-flight

The version is set in `apps/{midgard,packer,midgard_cli}/mix.exs`, `packages/erlang/src/midgard.app.src`, `packages/rebar3_midgard/src/rebar3_midgard.app.src`, and `packages/gleam/gleam.toml`. Docs, the website, the scaffold (`apps/midgard_cli/lib/midgard/cli/generator.ex`), and `examples/erlang_worker/rebar.config` reference it too:

```sh
grep -rn '0\.3\.0\|~> 0\.3' --include='*.md' --include='*.ex' --include='*.exs' \
  --include='*.src' --include='*.toml' --include='*.config' --include='*.tsx' \
  --exclude-dir=deps --exclude-dir=_build --exclude-dir=node_modules --exclude-dir=build .
```

Run the checks:

```sh
mix format --check-formatted && mix test
(cd packages/erlang && rebar3 eunit)
(cd packages/rebar3_midgard && rebar3 compile)
(cd examples/erlang_worker && rebar3 eunit)
(cd packages/gleam && gleam format --check src && gleam build --target erlang)
(cd examples/gleam_worker && gleam build --target erlang)
(cd sites/midgard.leostera.dev && bun test && bun run typecheck && bun run build)
```

Optionally inspect the tarballs without publishing: `mix hex.build` in each `apps/*` package, `rebar3 hex build` in each Rebar3 package, and `gleam export hex-tarball` in `packages/gleam`.

## 2. Authenticate

Each tool keeps its own Hex credentials:

```sh
mix hex.user auth
rebar3 hex user auth   # needs the rebar3_hex plugin in ~/.config/rebar3/rebar.config
```

`gleam publish` prompts for credentials, or reads `HEXPM_API_KEY`.

## 3. Publish

Publish the SDKs before the tools that scaffold projects depending on them:

```sh
(cd apps/midgard && mix hex.publish)
(cd apps/packer && mix hex.publish)
(cd apps/midgard_cli && mix hex.publish)
(cd packages/erlang && rebar3 hex publish)
(cd packages/rebar3_midgard && rebar3 hex publish)
(cd packages/gleam && gleam publish)
```

Confirm all six report the new version:

```sh
for p in midgard midgard_packer midgard_cli midgard_erlang midgard_gleam rebar3_midgard; do
  printf '%-16s ' "$p"; curl -fsS "https://hex.pm/api/packages/$p" | python3 -c 'import json,sys; print(json.load(sys.stdin)["latest_version"])'
done
```

## 4. Point the examples at Hex

Before the release, the Gleam example builds against the local SDK so unreleased changes can be tested. Switch it to the published package and refresh its manifest:

```sh
cd examples/gleam_worker
sed -i.bak 's|^midgard_gleam = .*|midgard_gleam = "0.3.0"|' gleam.toml && rm gleam.toml.bak
rm manifest.toml && gleam build --target erlang
cd ../..
```

The Erlang example keeps its `_checkouts` symlinks for development. Rebar3 skips them when it writes a lock, so move them aside to lock against Hex:

```sh
cd examples/erlang_worker
mv _checkouts /tmp/erlang-worker-checkouts
rm -rf _build && rebar3 upgrade --all
mv /tmp/erlang-worker-checkouts _checkouts
cd ../..
```

Run the Packer tests again (`mix test`), then commit and push.

## 5. Smoke-test the quickstarts

Run the website quickstarts against the published packages. Each one deploys a worker to the public demo and checks that `GET /` returns `Hello Joe!`:

```sh
scripts/smoke-test-quickstarts.sh            # or: elixir | gleam | erlang
```

The Elixir quickstart needs the pinned Elixir. The script reuses `/tmp/midgard-toolchain` (or `MIDGARD_ELIXIR_TOOLCHAIN`), and builds it if it's missing.

## 6. Deploy the website

The website shows the new install commands, so deploy it only after the packages are live:

```sh
cd sites/midgard.leostera.dev && bun run deploy
```
