# midgard.leostera.dev

The public hostname is served through **one edge Worker → one Elixir HTTP
service in a Cloudflare Container**. The service runs for the Container's
lifetime, not across Container shutdowns. `NativeRuntime` is the Container's
Durable Object lifecycle/port binding, not another application server. The
Worker limits requests and forwards allowed HTTP paths to Bandit through its
private TCP port. No `container.exec()` runs for a visitor request.

**Public demo: tokenless uploads and calls.** The edge accepts bounded binary
shipments from `mix midgard.deploy`, gives each upload a random immutable
hostname (`<app>-<id>.midgard.leostera.dev`), and forwards it with a DO-managed
internal key to the existing `Midgard.Platform.Router`. The public edge rewrites
that hostname to the platform's internal `/run/<slug>/` route; `/run` is not a
public URL. Each exact hostname is attached to the edge Worker through the
Cloudflare Workers Domains API. Configure the Worker secret
`CLOUDFLARE_API_TOKEN` with a token scoped to Workers Scripts Write before
accepting deployments. The DO persists exact shipment bytes in SQLite; a
fresh Container must independently verify and re-admit every stored shipment
before the dashboard or call routes become available. Browser source editing
and compilation remain local-only. Anonymous routes are publicly callable; no
account, update/delete authority, private tenant isolation or uptime guarantee
is implied. The shared demo admits at most 32 workers, a 24 MB upload, and two
uploads per client IP per minute. HTTP requests are rate limited separately.

Docker builds the deployment image **outside** Cloudflare. No Docker daemon or
Docker-in-Docker is required or supplied inside the running Container. The
base amd64 image was built from pinned source; `deploy/runtime/edge-http/`
overlays the compiled Elixir platform and Packer modules with matching
Elixir/OTP, without building or compiling in the serving Container.

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
