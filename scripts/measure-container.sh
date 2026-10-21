#!/usr/bin/env bash
# Boots the same worker in an ordinary container, for comparison with
# scripts/measure-deploy.sh. Each image contains the worker's exact Midgard
# shipment modules plus bench/container/midgard_http.erl, a dependency-free
# HTTP front that frames requests as midgard.bytes.v1 and calls the same
# entrypoint libbeam calls.
#
# Usage: scripts/measure-container.sh LANGUAGE=ARTIFACT_DIR [...]
#   e.g. scripts/measure-container.sh elixir=/path/elixir_worker.midgard gleam=...
# Measures image build time, image size, and `docker run` -> first
# "200 Hello Joe!" over MIDGARD_BOOT_RUNS runs (default 10). Results are
# appended as JSON lines to $MIDGARD_CONTAINER_LOG.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
runs="${MIDGARD_BOOT_RUNS:-10}"
base="${MIDGARD_BASE_IMAGE:-erlang:29-slim}"
log="${MIDGARD_CONTAINER_LOG:-/tmp/midgard-container-timings.jsonl}"
port=18181

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

measure() {
  local language="$1" artifact="$2"
  local context entry_module entry_function image start built size
  context="$(mktemp -d /tmp/midgard-container.XXXXXX)"
  entry_module="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["entrypoint"]["module"])' "$artifact/manifest.json")"
  entry_function="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["entrypoint"]["function"])' "$artifact/manifest.json")"
  cp -R "$artifact/modules" "$context/modules"
  cp "$root/bench/container/midgard_http.erl" "$context/"
  # -pz: the image's own OTP comes first; the shipment supplies everything else.
  cat > "$context/Dockerfile" <<EOF
FROM $base
WORKDIR /app
COPY midgard_http.erl modules/ /app/
RUN mkdir -p ebin modules && mv *.beam modules/ && erlc -o ebin midgard_http.erl && rm midgard_http.erl
ENV MIDGARD_ENTRY_MODULE=$entry_module MIDGARD_ENTRY_FUNCTION=$entry_function PORT=8080
EXPOSE 8080
CMD ["erl", "-noshell", "-pa", "/app/ebin", "-pz", "/app/modules", "-s", "midgard_http", "start"]
EOF
  image="midgard-bench-$language"
  start="$(now_ms)"
  docker build -q -t "$image" "$context" >/dev/null
  built="$(now_ms)"
  size="$(docker image inspect "$image" --format '{{.Size}}')"

  local boots=() run cid t0 t1 body
  for run in $(seq 1 "$runs"); do
    t0="$(now_ms)"
    cid="$(docker run -d --rm -p "$port:8080" "$image")"
    while true; do
      body="$(curl -s --max-time 1 "http://127.0.0.1:$port/" || true)"
      [ "$body" = "Hello Joe!" ] && break
      [ $(( $(now_ms) - t0 )) -lt 30000 ] || { docker logs "$cid"; docker rm -f "$cid" >/dev/null; return 1; }
      sleep 0.01
    done
    t1="$(now_ms)"
    boots+=($((t1 - t0)))
    docker rm -f "$cid" >/dev/null
  done

  python3 - "$language" "$base" "$((built - start))" "$size" "$(du -sk "$artifact/modules" | cut -f1)" "$log" "${boots[@]}" <<'PY'
import json, statistics, sys
language, base, build_ms, size, shipment_kb, log, *boots = sys.argv[1:]
boots = sorted(int(b) for b in boots)
row = {
    "language": language, "base_image": base, "image_build_ms": int(build_ms),
    "image_bytes": int(size), "shipment_kb": int(shipment_kb),
    "boot_ms_median": int(statistics.median(boots)), "boot_ms_min": boots[0], "boot_ms_max": boots[-1],
    "boot_ms_all": boots,
}
with open(log, "a") as handle:
    handle.write(json.dumps(row) + "\n")
print(f"  {language:<7} boot median {row['boot_ms_median']}ms (min {boots[0]}, max {boots[-1]})"
      f" | image {row['image_bytes'] / 1e6:.0f} MB, build {int(build_ms) / 1000:.1f}s | shipment {int(shipment_kb) / 1024:.1f} MB")
PY
  rm -rf "$context"
}

for pair in "$@"; do
  measure "${pair%%=*}" "${pair#*=}"
done
