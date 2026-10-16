#!/usr/bin/env bash
# Development-only build against a local libbeam checkout. A versioned native
# distribution/install target is required before publishing this Mix package.
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
: "${LIBBEAM_SOURCE:?Set LIBBEAM_SOURCE to the absolute libbeam source checkout}"
source=$(cd -- "$LIBBEAM_SOURCE" && pwd)
(cd "$source" && bazel build //libbeam:libbeam //libbeam:core)
mkdir -p "$root/priv"
"${CXX:-c++}" -std=c++17 -O2 -I"$source/libbeam/include" \
  "$root/native/libbeam_host.cpp" "$source/bazel-bin/libbeam/liblibbeam.a" \
  "$source/bazel-bin/libbeam/libcore.a" -lz -pthread \
  -o "$root/priv/libbeam_host"
printf 'Built %s/priv/libbeam_host\n' "$root"
