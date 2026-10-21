#!/usr/bin/env bash
# Deploys the same Gleam worker as a Cloudflare Container and times:
#   deploy          : `cf deploy` start -> command exits (image build + push + rollout)
#   until it answers: command exits -> the NEW image answers "200 Hello Joe!"
#   cold restart    : /__stop, then the next request until it answers
# Usage: bench/cloudflare-containers/measure.sh ARTIFACT_DIR [RUNS]
# Each run changes IMAGE_ID, so every deploy pushes a new image layer.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
artifact="$1"
runs="${2:-3}"
log="${MIDGARD_CF_CONTAINER_LOG:-/tmp/midgard-cf-container-timings.jsonl}"

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

prepare() {
  local image_id="$1" entry_module entry_function
  entry_module="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["entrypoint"]["module"])' "$artifact/manifest.json")"
  entry_function="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["entrypoint"]["function"])' "$artifact/manifest.json")"
  rm -rf "$here/image" && mkdir -p "$here/image"
  cp -R "$artifact/modules" "$here/image/modules"
  # Compiled here: the amd64 image build runs under emulation, where erlc crashes.
  erlc -o "$here/image" "$root/bench/container/midgard_http.erl"
  cat > "$here/image/Dockerfile" <<EOF
FROM erlang:29-slim
WORKDIR /app
COPY midgard_http.beam /app/ebin/
COPY modules/ /app/modules/
ENV MIDGARD_ENTRY_MODULE=$entry_module MIDGARD_ENTRY_FUNCTION=$entry_function PORT=8080 IMAGE_ID=$image_id
EXPOSE 8080
CMD ["erl", "-noshell", "-pa", "/app/ebin", "-pz", "/app/modules", "-s", "midgard_http", "start"]
EOF
}

# Polls until the given image answers; prints elapsed ms and the last wait header.
wait_for() {
  local url="$1" image_id="$2" t0 headers body
  t0="$(now_ms)"
  while true; do
    headers="$(mktemp)"
    body="$(curl -s -m 130 -D "$headers" "$url" || true)"
    if [ "$body" = "Hello Joe!" ] && grep -qi "^x-image-id: $image_id" "$headers"; then
      echo "$(( $(now_ms) - t0 )) $(grep -i '^x-container-wait-ms' "$headers" | tr -dc '0-9')"
      rm -f "$headers"; return
    fi
    rm -f "$headers"
    [ $(( $(now_ms) - t0 )) -lt 900000 ] || { echo "timed out" >&2; return 1; }
    sleep 0.5
  done
}

for run in $(seq 1 "$runs"); do
  image_id="run-$(date +%s)-$run"
  prepare "$image_id"
  out="$(mktemp)"
  t0="$(now_ms)"
  (cd "$here" && ./node_modules/.bin/cf deploy) > "$out" 2>&1 || { cat "$out"; exit 1; }
  t1="$(now_ms)"
  url="$(grep -oE 'https://midgard-container-bench\.[a-z0-9-]+\.workers\.dev' "$out" | head -1)"
  [ -n "$url" ] || { cat "$out"; echo "no workers.dev URL in deploy output" >&2; exit 1; }
  read -r answer_ms first_wait_ms < <(wait_for "$url/" "$image_id")
  curl -fsS "$url/__stop" >/dev/null
  sleep 2
  read -r restart_ms restart_wait_ms < <(wait_for "$url/" "$image_id")
  python3 - "$log" "$image_id" "$((t1 - t0))" "$answer_ms" "${first_wait_ms:-0}" "$restart_ms" "${restart_wait_ms:-0}" <<'PY'
import json, sys
log, image_id, deploy, answer, first_wait, restart, restart_wait = sys.argv[1:]
row = {"image_id": image_id, "deploy_ms": int(deploy), "until_answers_ms": int(answer),
       "first_container_wait_ms": int(first_wait), "cold_restart_ms": int(restart),
       "restart_container_wait_ms": int(restart_wait), "total_ms": int(deploy) + int(answer)}
open(log, "a").write(json.dumps(row) + "\n")
print(f"  run {image_id}: deploy {int(deploy)/1000:.1f}s, then answers after {int(answer)/1000:.1f}s"
      f" (total {row['total_ms']/1000:.1f}s) | cold restart {int(restart)/1000:.1f}s")
PY
  rm -f "$out"
done
