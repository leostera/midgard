#!/usr/bin/env bash
# Runs the README/website quickstarts for Elixir, Gleam, and Erlang against the
# published Hex packages, in throwaway directories with a fresh MIX_HOME.
# Each worker is deployed to the public demo and must answer GET / with
# "Hello Joe!". Usage: scripts/smoke-test-quickstarts.sh [elixir] [gleam] [erlang]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
version="${MIDGARD_VERSION:-$(sed -nE 's/^ *version: "([^"]+)",?$/\1/p' "$root/apps/midgard/mix.exs" | head -1)}"
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

# The demo rate-limits uploads, so retry the deploy. Only the Worker URL goes
# to stdout; progress and errors go to stderr so they can't be mistaken for it.
deploy() {
  local log="$1"; shift
  local attempt url
  for attempt in 1 2 3; do
    if "$@" >"$log" 2>&1; then
      url="$(grep -oE 'https://[a-z0-9-]+\.midgard\.leostera\.dev/' "$log" | head -1 || true)"
      [ -n "$url" ] && { echo "$url"; return 0; }
      echo "  deploy succeeded but printed no Worker URL:" >&2
      sed 's/^/    /' "$log" >&2
      return 1
    fi
    echo "  deploy failed (attempt $attempt):" >&2
    sed 's/^/    /' "$log" | tail -3 >&2
    [ "$attempt" = 3 ] && return 1
    echo "  retrying in 40s" >&2; sleep 40
  done
}

check_hello() {
  local url="$1" host ip nameserver body=""
  [[ "$url" =~ ^https://[a-z0-9-]+\.midgard\.leostera\.dev/$ ]] || { echo "  FAIL not a Worker URL: $url" >&2; return 1; }
  host="$(echo "$url" | sed -E 's|https://([^/]+)/|\1|')"
  nameserver="$(dig +short NS leostera.dev | head -1)"
  for _ in $(seq 1 20); do
    # Ask the authoritative nameserver: public resolvers cache the NXDOMAIN
    # from a poll made before the Worker's DNS record existed.
    ip="$(dig +short @"$nameserver" "$host" | grep -E '^[0-9.]+$' | head -1 || true)"
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
    minor="$(echo "$version" | cut -d. -f1,2)"
    grep -q "\"~> $minor\"" mix.exs || { echo "  scaffold does not use Hex $minor packages"; exit 1; }
    mix deps.get >/dev/null && mix test >/dev/null
    url="$(deploy "$work/elixir-deploy.log" mix midgard.deploy)" || exit 1
    check_hello "$url"
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
    url="$(deploy "$work/gleam-deploy.log" mix midgard.deploy --artifact hello_worker_gleam.midgard)" || exit 1
    check_hello "$url"
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
    url="$(deploy "$work/erlang-deploy.log" rebar3 midgard deploy)" || exit 1
    check_hello "$url"
  )
}

status=0
for language in "$@"; do
  "smoke_$language" || status=1
done
[ "$status" = 0 ] && echo "All quickstarts passed." || echo "Some quickstarts FAILED; logs in $work"
exit "$status"
