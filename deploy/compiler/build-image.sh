#!/usr/bin/env bash
# Build the compiler from committed SDK and compiler sources, never dirty files.
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
root=$(cd -- "$here/../.." && pwd)
revision=$(git -C "$root" rev-parse --verify HEAD)
context=$(mktemp -d "${TMPDIR:-/tmp}/midgard-compiler.XXXXXXXX")
trap 'rm -rf -- "$context"' EXIT
mkdir -p "$context/deploy/compiler"
cp "$here/Dockerfile" "$context/deploy/compiler/Dockerfile"
git -C "$root" archive "$revision" \
  apps/midgard_platform/priv/compiler/compile.exs \
  apps/midgard/lib/midgard/request.ex \
  apps/midgard/lib/midgard/protocol.ex \
  apps/midgard/lib/midgard/worker.ex | tar -xf - -C "$context"
image="midgard-compiler:${revision:0:12}"
docker buildx build --platform linux/amd64 --load \
  -f "$context/deploy/compiler/Dockerfile" -t "$image" "$context"
test "$(docker image inspect "$image" --format '{{.Architecture}}')" = amd64
printf 'Built %s from committed source %s\n' "$image" "$revision"
