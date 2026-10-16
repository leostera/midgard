#!/usr/bin/env bash
# Build the reviewed HTTP server overlay without running Elixir under QEMU.
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
root=$(cd -- "$here/../../.." && pwd)
revision=$(git -C "$root" rev-parse --verify HEAD)
git -C "$root" diff --exit-code HEAD -- \
  apps/midgard_platform/lib/midgard/platform/application.ex \
  apps/midgard_platform/lib/midgard/platform/page.ex >/dev/null
context=$(mktemp -d "${TMPDIR:-/tmp}/midgard-http.XXXXXXXX")
trap 'rm -rf -- "$context"' EXIT
mkdir -p "$context/source" "$context/image/ebin"
git -C "$root" archive "$revision" | tar -xf - -C "$context/source"
(
  cd "$context/source"
  export MIX_ENV=prod
  mix deps.get
  mix compile
)
cp "$context/source/_build/prod/lib/midgard_platform/ebin/"*.beam "$context/image/ebin/"
cp "$context/source/apps/midgard_platform/lib/midgard/platform/application.ex" "$context/image/application.ex"
cp "$context/source/apps/midgard_platform/lib/midgard/platform/page.ex" "$context/image/page.ex"
image="midgard-http:${revision:0:12}"
docker buildx build --platform linux/amd64 --load \
  --build-arg "MIDGARD_SOURCE_COMMIT=$revision" \
  -f "$here/Dockerfile" -t "$image" "$context/image"
test "$(docker image inspect "$image" --format '{{.Architecture}}')" = amd64
printf 'Built %s from committed source %s\n' "$image" "$revision"
