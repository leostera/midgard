# midgard.leostera.dev

The public hostname is served through **one edge Worker → one Elixir HTTP
service in a Cloudflare Container**. The service runs for the Container's
lifetime, not across Container shutdowns. `NativeRuntime` is the Container's
Durable Object lifecycle/port binding, not another application server. The
Worker limits requests and forwards allowed HTTP paths to Bandit through its
private TCP port. No `container.exec()` runs for a visitor request.

**Current public scope: read-only inventory.** Public writes remain closed. The
existing `Midgard.Platform.Router` handles the dashboard and its static assets;
it has not been replaced by another API. Its Create action still calls the
trusted-local `Midgard.Platform.Compiler`, which requires a local Docker daemon
and cannot run inside this Container. Its workspace is also ephemeral after
Container shutdown, and native Isolate handles are lost after BEAM restarts.
Rate limiting does not solve either problem. Do not mark a revision Deployed
until its exact stored shipment has been re-verified and admitted into libbeam.

Docker builds the deployment image **outside** Cloudflare. No Docker daemon or
Docker-in-Docker is required or supplied inside the running Container. The
base amd64 image was built from pinned source; `deploy/runtime/edge-http/`
overlays only pure Elixir BEAMs compiled with the matching Elixir/OTP version.

```sh
cd sites/midgard.leostera.dev
bun install --frozen-lockfile
bun run test
bun run typecheck
cf deploy --dry-run
cf deploy
curl -i https://midgard.leostera.dev/
```

Pushes do not automatically deploy. Use an authenticated local `cf` session
for reviewed site releases; never embed account credentials in browser code.
