# Local hybrid to-do example

The `worker` Mix app combines `TodoWorker` (Elixir binary HTTP adapter) with `:todo_store` (Erlang `gen_server` state). The separate `web` Mix app runs that worker on **ordinary OTP** behind a loopback-only Bandit/Plug listener. The web host and its dependencies are not packaged as guest worker capabilities. There is no database: the list resets when the server restarts.

## Run the browser UI and JSON API

Requires Elixir 1.19+ and a compatible OTP installation. Run from this repository checkout:

```sh
cd examples/todo/web
mix deps.get
mix test
mix run --no-halt
```

Open <http://127.0.0.1:4100/>. Set `TODO_PORT` to another available TCP port before `mix run` if needed; the listener still binds **only** to `127.0.0.1`. The page renders the current list on the server, then uses a small same-origin script for create, edit, complete, and two-step inline remove actions. Browser mutations send the token embedded in the page and are checked against the local origin. This is a local demonstration safeguard, **not** an authentication or production-security design. Task titles are 1–160 UTF-8 bytes, and the list has at most 60 items so even heavily escaped JSON remains within Midgard's 64 KiB response frame.

An optional real-browser regression check requires Node.js 20+, `npm ci` in `examples/todo/web`, and an installed Chrome/Chromium executable selected with `CHROME_PATH`. Run `CHROME_PATH=/path/to/chrome npm run test:browser` from `examples/todo/web`; it starts and stops its own fresh loopback server, exercises empty, positive/negative CRUD, and checks desktop and mobile layouts. Set `MIDGARD_SCREENSHOT_DIR=/tmp/todo-captures` to save full-page screenshots.

The API is `GET /api/todos`, `POST /api/todos` with `{"title":"..."}`, `PATCH /api/todos/:id` with `{"title":"..."}` and/or `{"completed":true}`, and `DELETE /api/todos/:id`. Read-only GET needs no token. For a shell mutation, first obtain the per-server token from the local page and send both that token and the local Origin:

```sh
TOKEN=$(curl -fsS http://127.0.0.1:4100/ | grep -o 'name="csrf-token" content="[^"]*"' | cut -d '"' -f4)
curl -fsS -X POST http://127.0.0.1:4100/api/todos \
  -H 'Content-Type: application/json' \
  -H 'Origin: http://127.0.0.1:4100' \
  -H "x-csrf-token: $TOKEN" \
  --data '{"title":"Review the build"}'
curl -fsS http://127.0.0.1:4100/api/todos
```

## Build the separate worker artifact

```sh
cd examples/todo/worker
mix deps.get
mix test
mix midgard.build
mix packer.inspect todo_worker.midgard
mix packer.inspect todo_worker.midgard --target current-core
```

The final `--target current-core` command is **expected to fail** with static blockers. The artifact is a versioned, inspectable handoff with exact-name Elixir and Erlang BEAMs, not an executable local host. Neither this hybrid worker nor its state process has been run inside libbeam. `rebar3` is needed for the separate standalone Erlang fixture, not for this Mix example; see [Erlang project support](../../docs/erlang-projects.md).
