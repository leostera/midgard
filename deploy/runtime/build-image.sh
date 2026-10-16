#!/usr/bin/env bash
# Build a linux/amd64 native host from three committed, reviewable source trees.
# The context contains only git-archived files; it cannot absorb local secrets.
set -euo pipefail

here=$(cd -- "$(dirname -- "$0")" && pwd)
root=$(cd -- "$here/../.." && pwd)
: "${LIBBEAM_SOURCE:?Set LIBBEAM_SOURCE to a checkout of leostera/libbeam}"
: "${ELIXIR_SOURCE:?Set ELIXIR_SOURCE to a checkout of elixir-lang/elixir}"
libbeam_revision=b104952047cbdee7f2d4469de7375428df23a43a
elixir_revision=13299af2b91a6aff7e430f25849f586c02b3231f
midgard_revision=$(git -C "$root" rev-parse --verify HEAD)

git -C "$LIBBEAM_SOURCE" cat-file -e "${libbeam_revision}^{commit}"
git -C "$ELIXIR_SOURCE" cat-file -e "${elixir_revision}^{commit}"

context=$(mktemp -d "${TMPDIR:-/tmp}/midgard-runtime.XXXXXXXX")
trap 'rm -rf -- "$context"' EXIT

for tree in midgard-source libbeam-source elixir-source; do
  mkdir -p "$context/$tree"
done
git -C "$root" archive "$midgard_revision" | tar -xf - -C "$context/midgard-source"
git -C "$LIBBEAM_SOURCE" archive "$libbeam_revision" | tar -xf - -C "$context/libbeam-source"
git -C "$ELIXIR_SOURCE" archive "$elixir_revision" | tar -xf - -C "$context/elixir-source"

image="midgard-runtime:${midgard_revision:0:12}"
printf 'Building %s with libbeam %s and Elixir %s\n' \
  "$image" "$libbeam_revision" "$elixir_revision"
docker buildx build --platform linux/amd64 --load \
  --build-arg "MIDGARD_SOURCE_COMMIT=$midgard_revision" \
  -f "$here/Dockerfile" -t "$image" "$context"
printf 'Built %s\n' "$image"
