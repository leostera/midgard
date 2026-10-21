#!/usr/bin/env bash
# Measures, per language:
#   time to deploy       : deploy command start -> Worker URL printed
#                          (local build + readiness check + upload/admission)
#   time to serviceable  : Worker URL printed -> the edge serves "200 Hello Joe!"
#                          AND the authoritative nameserver has the hostname
#   No caching resolver is queried for the new hostname: one asked too early
#   caches NXDOMAIN for the zone's negative TTL (30 minutes).
#
# Usage: scripts/measure-deploy.sh [elixir] [gleam] [erlang]
# Each run deploys a real worker to the public demo. Results are printed as a
# table and appended as JSON lines to $MIDGARD_MEASURE_LOG (default
# /tmp/midgard-deploy-timings.jsonl).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
log="${MIDGARD_MEASURE_LOG:-/tmp/midgard-deploy-timings.jsonl}"
elixir_toolchain="${MIDGARD_ELIXIR_TOOLCHAIN:-/tmp/midgard-toolchain}"
export HEX_CACERTS_PATH="${HEX_CACERTS_PATH:-/etc/ssl/cert.pem}"
if [ "$#" -eq 0 ]; then set -- elixir gleam erlang; fi

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

# Prefix each output line with milliseconds since the epoch, as it arrives.
stamp() { python3 -u -c '
import sys, time
for line in sys.stdin:
    print(f"{int(time.time() * 1000)}\t{line}", end="", flush=True)'; }

first_at() { awk -F'\t' -v pattern="$2" '$2 ~ pattern { print $1; exit }' "$1"; }

# Deploys with "$@", then polls the new hostname until it serves Hello Joe!.
measure() {
  local language="$1"; shift
  local out; out="$(mktemp /tmp/midgard-measure.XXXXXX)"
  local start end_cmd url host ip="" dns_at="" first_at_ms="" warm_request_ms="" attempts=0

  start="$(now_ms)"
  "$@" 2>&1 | stamp > "$out" || { cut -f2- "$out"; echo "deploy failed" >&2; return 1; }
  end_cmd="$(now_ms)"
  url="$(grep -oE 'https://[a-z0-9-]+\.midgard\.leostera\.dev/' "$out" | head -1 || true)"
  [ -n "$url" ] || { cut -f2- "$out"; echo "no Worker URL printed" >&2; return 1; }
  local url_at; url_at="$(first_at "$out" 'Worker URL:')"
  local ready_at; ready_at="$(first_at "$out" 'Checking public runtime')"
  # rebar3 prints the CLI's output only when it exits, so it has no phase marks.
  [ "$language" != erlang ] || ready_at=""
  local deployed_at; deployed_at="$(first_at "$out" '^Deployed ')"
  host="${url#https://}"; host="${host%/}"

  # Poll without touching any caching resolver: a resolver asked before the
  # record exists caches NXDOMAIN for the zone's negative TTL (30 minutes).
  #  - edge: request the new hostname at the edge IP of the main site
  #  - dns:  ask the zone's authoritative nameserver, which never caches
  local edge_ip nameserver edge_at="" first_request_ms="" seconds code result
  edge_ip="$(dig +short @1.1.1.1 midgard.leostera.dev A | grep -E '^[0-9.]+$' | head -1)"
  nameserver="$(dig +short leostera.dev NS | head -1)"
  while [ -z "$edge_at" ] || [ -z "$dns_at" ]; do
    attempts=$((attempts + 1))
    [ "$attempts" -le 2400 ] || { echo "$url never became serviceable" >&2; return 1; }
    if [ -z "$dns_at" ] && dig +short +time=1 +tries=1 "@$nameserver" "$host" A | grep -qE '^[0-9.]+$'; then
      dns_at="$(now_ms)"
    fi
    if [ -z "$edge_at" ]; then
      result="$(curl -sS -o /tmp/midgard-measure-body -w '%{http_code} %{time_total}' --max-time 30 \
        --resolve "$host:443:$edge_ip" "$url" 2>/dev/null || echo "000 0")"
      code="${result%% *}"; seconds="${result##* }"
      if [ "$code" = 200 ] && [ "$(cat /tmp/midgard-measure-body)" = "Hello Joe!" ]; then
        edge_at="$(now_ms)"; first_request_ms="$(python3 -c "print(round($seconds * 1000))")"
      fi
    fi
    { [ -n "$edge_at" ] && [ -n "$dns_at" ]; } || sleep 0.25
  done
  ip="$edge_ip"
  first_at_ms="$edge_at"
  warm_request_ms="$(curl -sS -o /dev/null -w '%{time_total}' --resolve "$host:443:$ip" "$url" |
    python3 -c 'import sys; print(round(float(sys.stdin.read()) * 1000))')"

  python3 - "$language" "$url" "$start" "$ready_at" "$deployed_at" "$url_at" "$end_cmd" \
    "$dns_at" "$first_at_ms" "$first_request_ms" "$warm_request_ms" "$attempts" "$log" <<'PY'
import json, sys
(language, url, start, ready, deployed, url_at, end_cmd, dns, first, first_req, warm, attempts, log) = sys.argv[1:]
ms = lambda value: int(value) if value else None
start, ready, deployed, url_at, end_cmd, dns, first = map(ms, (start, ready, deployed, url_at, end_cmd, dns, first))
url_at = url_at or end_cmd
row = {
    "language": language,
    "url": url,
    "deploy_ms": url_at - start,
    "build_ms": (ready - start) if ready else None,
    "upload_and_admit_ms": (url_at - ready) if ready else None,
    "edge_serviceable_ms": first - url_at,
    "first_request_ms": int(first_req),
    "authoritative_dns_ms": dns - url_at,
    "serviceable_ms": max(first, dns) - url_at,
    "total_ms": max(first, dns) - start,
    "warm_request_ms": int(warm),
    "poll_attempts": int(attempts),
}
with open(log, "a") as handle:
    handle.write(json.dumps(row) + "\n")
s = lambda value: "-" if value is None else f"{value / 1000:.1f}s"
print(f"  {language:<7} deploy {s(row['deploy_ms'])} (build {s(row['build_ms'])}, upload+admit {s(row['upload_and_admit_ms'])})"
      f" | serviceable {s(row['serviceable_ms'])} (edge {s(row['edge_serviceable_ms'])}, first request {row['first_request_ms']}ms,"
      f" authoritative DNS {s(row['authoritative_dns_ms'])}) | total {s(row['total_ms'])} | warm {row['warm_request_ms']}ms")
PY
  rm -f "$out"
}

measure_elixir() {
  local dir; dir="$(mktemp -d /tmp/midgard-measure-elixir.XXXXXX)"
  (
    export PATH="$elixir_toolchain/bin:$PATH"
    cd "$dir" && mix midgard.new elixir_worker >/dev/null && cd elixir_worker
    mix deps.get >/dev/null && mix compile >/dev/null
    measure elixir mix midgard.deploy
  )
}

measure_gleam() {
  (
    cd "$root/examples/gleam_worker"
    measure gleam bash -c 'mix packer.pack --project . --gleam --entry gleam_worker --function handle \
      --protocol midgard.bytes.v1 --output /tmp/midgard-measure-gleam.midgard >/dev/null &&
      mix midgard.deploy --artifact /tmp/midgard-measure-gleam.midgard'
  )
}

measure_erlang() {
  (
    cd "$root/examples/erlang_worker"
    measure erlang rebar3 midgard deploy
    # rebar3 rewrites the lock while _checkouts are present.
    git -C "$root" checkout -q -- examples/erlang_worker/rebar.lock
  )
}

echo "Results are appended to $log"
first=1
for language in "$@"; do
  # The public demo allows two deploys per minute per IP.
  [ "$first" = 1 ] || sleep 31
  first=0
  "measure_$language"
done
