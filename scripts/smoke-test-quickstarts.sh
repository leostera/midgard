#!/usr/bin/env bash
# Runs the README/website quickstarts for Elixir, Gleam, and Erlang against the
# published Hex packages, in throwaway directories with a fresh MIX_HOME.
# Each worker is deployed to the public demo and must answer GET / with
# "Hello Joe!". Usage: scripts/smoke-test-quickstarts.sh [elixir] [gleam] [erlang]
set -euo pipefail

version="${MIDGARD_VERSION:-0.3.0}"
elixir_toolchain="${MIDGARD_ELIXIR_TOOLCHAIN:-/tmp/midgard-toolchain}"
if [ "$#" -eq 0 ]; then set -- elixir gleam erlang; fi

work="$(mktemp -d /tmp/midgard-smoke.XXXXXX)"
export MIX_HOME="$work/mix"
export HEX_CACERTS_PATH="${HEX_CACERTS_PATH:-/etc/ssl/cert.pem}"
echo "Working in $work"

install_archives() {
  mix local.hex --force >/dev/null
  mix archive.install hex midgard_packer "$version" --force >/dev/null
  mix archive.install hex midgard_cli "$version" --force >/dev/null
}

# The demo rate-limits uploads, and new worker hostnames can take a moment to
# resolve, so retry the deploy and resolve through a public DNS server.
deploy() {
  local log="$1"; shift
  for attempt in 1 2 3; do
    if "$@" >"$log" 2>&1; then break; fi
    if [ "$attempt" = 3 ]; then cat "$log"; return 1; fi
    echo "  deploy failed (attempt $attempt), retrying in 40s"; sleep 40
  done
  grep -o 'https://[a-z0-9-]*\.midgard\.leostera\.dev/' "$log" | head -1
}

check_hello() {
  local url="$1" host ip body
  host="$(echo "$url" | sed -E 's|https://([^/]+)/|\1|')"
  for _ in $(seq 1 20); do
    ip="$(dig +short @1.1.1.1 "$host" | grep -E '^[0-9.]+$' | head -1 || true)"
    if [ -n "$ip" ]; then
      body="$(curl -fsS --resolve "$host:443:$ip" "$url" || true)"
      if [ "$body" = "Hello Joe!" ]; then echo "  OK  $url -> $body"; return 0; fi
    fi
    sleep 3
  done
  echo "  FAIL $url did not answer Hello Joe! (last body: ${body:-<none>})"; return 1
}

smoke_elixir() {
  echo "== Elixir"
  if [ ! -x "$elixir_toolchain/bin/elixir" ]; then
    git clone -q https://github.com/elixir-lang/elixir.git "$work/elixir"
    git -C "$work/elixir" checkout -q 13299af2b91a6aff7e430f25849f586c02b3231f
    make -C "$work/elixir" compile install PREFIX="$elixir_toolchain" >/dev/null
  fi
  (
    export PATH="$elixir_toolchain/bin:$PATH"
    install_archives
    cd "$work" && mix midgard.new hello_worker >/dev/null
    cd hello_worker
    grep -q '"~> 0.3"' mix.exs || { echo "  scaffold does not use Hex 0.3 packages"; exit 1; }
    mix deps.get >/dev/null && mix test >/dev/null
    check_hello "$(deploy "$work/elixir-deploy.log" mix midgard.deploy)"
  )
}

smoke_gleam() {
  echo "== Gleam"
  (
    install_archives
    cd "$work" && gleam new hello_worker_gleam >/dev/null && cd hello_worker_gleam
    gleam remove gleam_stdlib >/dev/null
    gleam add "midgard_gleam@$version" >/dev/null
    cat > src/hello_worker_gleam.gleam <<'EOF'
import midgard

pub fn handle(input: BitArray) -> BitArray {
  midgard.serve(input, handle_request)
}

pub fn handle_request(request: midgard.Request) -> midgard.Response {
  case request.method, request.path {
    <<"GET":utf8>>, <<"/":utf8>> -> midgard.Response(200, <<"Hello Joe!":utf8>>)
    _, _ -> midgard.Response(404, <<"Not found\n":utf8>>)
  }
}
EOF
    mix packer.pack --project . --gleam --entry hello_worker_gleam \
      --function handle --protocol midgard.bytes.v1 >/dev/null
    check_hello "$(deploy "$work/gleam-deploy.log" mix midgard.deploy --artifact hello_worker_gleam.midgard)"
  )
}

smoke_erlang() {
  echo "== Erlang"
  (
    install_archives
    cd "$work" && rebar3 new lib hello_worker_erl >/dev/null && cd hello_worker_erl
    cat > rebar.config <<EOF
{erl_opts, [debug_info]}.
{deps, [{midgard, "$version", {pkg, midgard_erlang}}]}.
{project_plugins, [{rebar3_midgard, "$version"}]}.
{midgard, [{entry, hello_worker_erl}, {function, handle},
           {protocol, "midgard.bytes.v1"}]}.
EOF
    cat > src/hello_worker_erl.erl <<'EOF'
-module(hello_worker_erl).
-include_lib("midgard/include/midgard.hrl").
-export([handle/1]).

handle(Input) -> midgard:serve(Input, fun handle_request/1).

handle_request(#midgard_request{method = <<"GET">>, path = <<"/">>}) ->
    #midgard_response{status = 200, body = <<"Hello Joe!">>};
handle_request(_Request) ->
    #midgard_response{status = 404, body = <<"Not found\n">>}.
EOF
    check_hello "$(deploy "$work/erlang-deploy.log" rebar3 midgard deploy)"
  )
}

status=0
for language in "$@"; do
  "smoke_$language" || status=1
done
[ "$status" = 0 ] && echo "All quickstarts passed." || echo "Some quickstarts FAILED; logs in $work"
exit "$status"
