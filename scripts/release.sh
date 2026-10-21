#!/usr/bin/env bash
# Reproducible release for all six Midgard packages. They share one version
# and are always published together. See RELEASING.md for the full process.
#
#   scripts/release.sh bump VERSION   set VERSION everywhere; point examples at local SDKs
#   scripts/release.sh check          run every test suite and build all six tarballs
#   scripts/release.sh publish [--dry-run]  publish all six packages to Hex (resumable)
#   scripts/release.sh finalize       point examples at Hex, refresh locks, test, commit, push
#   scripts/release.sh smoke          run the website quickstarts against Hex
#   scripts/release.sh deploy-site    deploy midgard.leostera.dev and verify it
#   scripts/release.sh all            check, publish, finalize, smoke, deploy-site
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
export HEX_CACERTS_PATH="${HEX_CACERTS_PATH:-/etc/ssl/cert.pem}"

packages=(midgard midgard_packer midgard_cli midgard_erlang rebar3_midgard midgard_gleam)

# Files that pin the release version. `bump` rewrites exactly these.
version_files=(
  apps/midgard/mix.exs apps/packer/mix.exs apps/midgard_cli/mix.exs
  packages/erlang/src/midgard.app.src packages/rebar3_midgard/src/rebar3_midgard.app.src
  packages/gleam/gleam.toml
  apps/midgard_cli/lib/midgard/cli/generator.ex apps/midgard_cli/test/generator_test.exs
  apps/packer/test/gleam_test.exs apps/packer/test/rebar3_test.exs
  examples/erlang_worker/rebar.config
  README.md apps/midgard/README.md apps/packer/README.md
  packages/erlang/README.md packages/gleam/README.md packages/rebar3_midgard/README.md
  sites/midgard.leostera.dev/src/ui/App.tsx
)

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

current_version() {
  sed -nE 's/^ *version: "([^"]+)",?$/\1/p' apps/midgard/mix.exs | head -1
}

minor() { echo "$1" | cut -d. -f1,2; }

strip_ansi() { sed -E $'s/\x1b\\[[0-9;]*m//g'; }

hex_has_version() {
  curl -fsS -o /dev/null "https://hex.pm/api/packages/$1/releases/$2" 2>/dev/null
}

# Every package must declare the same version before anything is published.
assert_versions_consistent() {
  local version="$1" found
  found="$(
    sed -nE 's/^ *version: "([^"]+)",?$/\1/p' apps/midgard/mix.exs apps/packer/mix.exs apps/midgard_cli/mix.exs
    sed -nE 's/.*\{vsn, "([^"]+)"\}.*/\1/p' packages/erlang/src/midgard.app.src packages/rebar3_midgard/src/rebar3_midgard.app.src
    sed -nE 's/^version = "([^"]+)"/\1/p' packages/gleam/gleam.toml
  )"
  [ "$(echo "$found" | sort -u)" = "$version" ] ||
    die "package versions disagree (expected $version):"$'\n'"$found"
}

gleam_example_dep() {
  sed -i.bak "s|^midgard_gleam = .*|midgard_gleam = $1|" examples/gleam_worker/gleam.toml
  rm examples/gleam_worker/gleam.toml.bak
  rm -f examples/gleam_worker/manifest.toml
  (cd examples/gleam_worker && rm -rf build && gleam build --target erlang >/dev/null)
}

cmd_bump() {
  local new="${1:-}" old
  [[ "$new" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: scripts/release.sh bump X.Y.Z"
  old="$(current_version)"
  [ "$old" != "$new" ] || die "already at $new"
  step "Bumping $old -> $new"
  local old_re="${old//./\\.}" old_minor_re
  old_minor_re="$(minor "$old")"; old_minor_re="${old_minor_re//./\\.}"
  for file in "${version_files[@]}"; do
    sed -i.bak -E "s/~> ${old_minor_re}\"/~> $(minor "$new")\"/g; s/${old_re}/${new}/g" "$file"
    rm "$file.bak"
  done
  assert_versions_consistent "$new"

  step "Pointing the Gleam example at the local SDK until $new is published"
  gleam_example_dep '{ path = "../../packages/gleam" }'

  step "Files that still mention $old (review these by hand)"
  git grep -n -F "$old" -- ':!*.lock' ':!*manifest.toml' ':!RELEASING.md' || echo "none"
  echo
  echo "Next: review the diff, run 'scripts/release.sh check', then commit and push."
}

cmd_check() {
  local version; version="$(current_version)"
  assert_versions_consistent "$version"
  step "Elixir umbrella"
  mix format --check-formatted
  mix test
  step "Erlang SDK, Rebar3 plugin, Erlang example"
  (cd packages/erlang && rebar3 eunit)
  (cd packages/rebar3_midgard && rebar3 compile)
  (cd examples/erlang_worker && rebar3 eunit)
  # Rebar3 rewrites the example lock to [] while _checkouts are present.
  git checkout -- examples/erlang_worker/rebar.lock
  step "Gleam SDK and example"
  (cd packages/gleam && gleam format --check src && gleam build --target erlang)
  (cd examples/gleam_worker && gleam format --check src && gleam build --target erlang)
  step "Website"
  (cd sites/midgard.leostera.dev && bun install --frozen-lockfile >/dev/null && bun test && bun run typecheck && bun run build)

  step "Building all six Hex tarballs for $version (nothing is published)"
  local out; out="$(mktemp -d /tmp/midgard-tarballs.XXXXXX)"
  for app in midgard packer midgard_cli; do
    (cd "apps/$app" && mix hex.build -o "$out/$app.tar" >/dev/null)
  done
  for pkg in erlang rebar3_midgard; do
    (cd "packages/$pkg" && rebar3 hex build >/dev/null)
    cp packages/$pkg/_build/default/lib/*/hex/*-"$version".tar "$out/"
  done
  (cd packages/gleam && gleam export hex-tarball >/dev/null)
  cp "packages/gleam/build/midgard_gleam-$version.tar" "$out/"
  local metadata
  for tarball in "$out"/*.tar; do
    metadata="$(tar -xOf "$tarball" metadata.config)"
    [[ "$metadata" == *"\"$version\""* ]] || die "$(basename "$tarball") does not declare version $version"
    [[ "$metadata" == *README.md* ]] || die "$(basename "$tarball") is missing README.md"
  done
  rm -rf packages/gleam/build "$out"
  echo "All checks passed and all six tarballs build at $version."
}

cmd_publish() {
  local dry_run=""
  [ "${1:-}" = "--dry-run" ] && dry_run=1
  local version; version="$(current_version)"
  assert_versions_consistent "$version"

  step "Pre-flight"
  [ -z "$(git status --porcelain)" ] || die "working tree is not clean"
  git fetch -q origin
  [ "$(git rev-parse HEAD)" = "$(git rev-parse '@{upstream}')" ] || die "HEAD is not pushed to its upstream"
  # Both tools exit 0 when signed out, so read what they print instead.
  local mix_whoami mix_user rebar3_user
  mix_whoami="$(mix hex.user whoami 2>&1 | strip_ansi || true)"
  mix_user="$(grep -vE '^\s*$|notice|Failed|error|No authenticated' <<< "$mix_whoami" | tail -1 || true)"
  if [ -z "$mix_user" ] || grep -qE 'Failed to auth|auth_error|No authenticated' <<< "$mix_whoami"; then
    die "not signed in to Hex for Mix; run: mix hex.user auth"
  fi
  rebar3_user="$(cd packages/rebar3_midgard && rebar3 hex user whoami 2>&1 | strip_ansi | awk '$1 == "hexpm" { print $2 }')"
  [ -n "$rebar3_user" ] || die "not signed in to Hex for Rebar3; run: rebar3 hex user auth"
  echo "Mix: $mix_user · Rebar3: $rebar3_user"
  echo "Gleam will ask for its own credentials (or set HEXPM_API_KEY)."

  step "Publishing $version (packages already at $version are skipped)"
  for package in "${packages[@]}"; do
    if hex_has_version "$package" "$version"; then
      echo "  $package $version is already on Hex, skipping"
      continue
    fi
    if [ -n "$dry_run" ]; then echo "  would publish $package $version"; continue; fi
    echo "  publishing $package $version"
    case "$package" in
      midgard) (cd apps/midgard && mix hex.publish package --yes) ;;
      midgard_packer) (cd apps/packer && mix hex.publish package --yes) ;;
      midgard_cli) (cd apps/midgard_cli && mix hex.publish package --yes) ;;
      midgard_erlang) (cd packages/erlang && rebar3 hex publish package --yes) ;;
      rebar3_midgard) (cd packages/rebar3_midgard && rebar3 hex publish package --yes) ;;
      midgard_gleam) (cd packages/gleam && gleam publish --yes && rm -rf build) ;;
    esac
  done

  [ -z "$dry_run" ] || { echo "Dry run: nothing was published."; return; }
  step "Waiting for Hex to list every package at $version"
  for package in "${packages[@]}"; do
    for _ in $(seq 1 30); do hex_has_version "$package" "$version" && break; sleep 5; done
    hex_has_version "$package" "$version" || die "$package $version is not visible on Hex"
    printf '  %-16s %s\n' "$package" "$version"
  done
}

cmd_finalize() {
  local version; version="$(current_version)"
  for package in "${packages[@]}"; do
    hex_has_version "$package" "$version" || die "$package $version is not on Hex yet; run publish first"
  done

  step "Pointing the Gleam example at midgard_gleam $version on Hex"
  gleam_example_dep "\"$version\""

  step "Locking the Erlang example against Hex"
  # Rebar3 never locks _checkouts, so move them aside (and always restore them).
  checkouts="$(mktemp -d /tmp/erlang-worker-checkouts.XXXXXX)"
  mv examples/erlang_worker/_checkouts "$checkouts/"
  trap 'mv "$checkouts/_checkouts" "$root/examples/erlang_worker/" 2>/dev/null || true' EXIT
  (cd examples/erlang_worker && rm -rf _build && rebar3 upgrade --all >/dev/null && rebar3 eunit >/dev/null)
  grep -q "\"$version\"" examples/erlang_worker/rebar.lock || die "rebar.lock does not pin $version"
  mv "$checkouts/_checkouts" examples/erlang_worker/
  trap - EXIT
  rm -rf examples/erlang_worker/_build

  step "Re-running Packer tests against the published SDKs"
  (cd apps/packer && mix test)

  step "Committing"
  git add examples/gleam_worker/gleam.toml examples/gleam_worker/manifest.toml examples/erlang_worker/rebar.lock
  if git diff --cached --quiet; then
    echo "Examples already point at Hex $version."
  else
    git commit -qm "release: point examples at Hex v$version"
    git push -q
    git log -1 --oneline
  fi
}

cmd_smoke() {
  MIDGARD_VERSION="$(current_version)" scripts/smoke-test-quickstarts.sh "$@"
}

cmd_deploy_site() {
  local version; version="$(current_version)"
  for package in "${packages[@]}"; do
    hex_has_version "$package" "$version" || die "$package $version is not on Hex; the site would show broken install commands"
  done
  step "Deploying midgard.leostera.dev"
  (cd sites/midgard.leostera.dev && bun test >/dev/null && bun run typecheck >/dev/null && bun run deploy)

  step "Verifying the live site serves $version instructions"
  # Download first: under pipefail, `curl | grep -q` fails when grep exits early.
  local page asset bundle
  page="$(curl -fsS https://midgard.leostera.dev/)"
  asset="$(sed -nE 's/.*src="(\/assets\/[^"]+\.js)".*/\1/p' <<< "$page" | head -1)"
  [ -n "$asset" ] || die "could not find the site bundle"
  bundle="$(curl -fsS "https://midgard.leostera.dev$asset")"
  [[ "$bundle" == *"midgard_gleam@$version"* ]] ||
    die "live bundle $asset does not mention midgard_gleam@$version"
  echo "Live: https://midgard.leostera.dev ($asset)"
}

cmd_all() {
  cmd_check
  cmd_publish
  cmd_finalize
  cmd_smoke
  cmd_deploy_site
  step "Released $(current_version)"
}

command="${1:-}"; shift || true
case "$command" in
  bump) cmd_bump "$@" ;;
  check) cmd_check ;;
  publish) cmd_publish "$@" ;;
  finalize) cmd_finalize ;;
  smoke) cmd_smoke "$@" ;;
  deploy-site) cmd_deploy_site ;;
  all) cmd_all ;;
  *) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 1 ;;
esac
