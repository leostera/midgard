#!/usr/bin/env bash
# Only tracked source at this pinned commit enters the compiler image.
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
: "${ELIXIR_SOURCE:?Set ELIXIR_SOURCE to the pinned Elixir checkout}"
commit=13299af2b91a6aff7e430f25849f586c02b3231f
actual=$(git -C "$ELIXIR_SOURCE" rev-parse HEAD)
if [[ "$actual" != "$commit" ]]; then
  printf 'Expected Elixir %s, got %s\n' "$commit" "$actual" >&2
  exit 1
fi
context=$(mktemp -d)
trap 'rm -rf "$context"' EXIT
mkdir "$context/elixir"
git -C "$ELIXIR_SOURCE" archive "$commit" | tar -xf - -C "$context/elixir"
cp "$here/Dockerfile" "$context/Dockerfile"
docker build --pull=false -t midgard-elixir-compiler:13299af "$context"
docker image inspect midgard-elixir-compiler:13299af --format 'Compiler image: {{.Id}}'
