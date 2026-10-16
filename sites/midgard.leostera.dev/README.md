# midgard.leostera.dev

This Cloudflare Worker owns the **single public hostname** `midgard.leostera.dev`.
Cloudflare provisions its proxied DNS record and TLS certificate from the
`domains` entry in `cloudflare.config.ts`.

**Current release is a holding response, not the Midgard platform.** It returns
503 with `no-store` and `noindex` because the trusted-local Elixir editor and
native libbeam host are not safe for anonymous public source uploads. Do not
proxy the local server, embed Cloudflare credentials in browser code, or mark
workers live before verified native admission.

```sh
cd sites/midgard.leostera.dev
bun install --frozen-lockfile
bun run test
bun run typecheck
bun run build
cf deploy --dry-run
cf deploy
curl -i https://midgard.leostera.dev/
```

For now, deploy after each reviewed **site** commit using an authenticated local
`cf` session. The repository has no CI deployment secret or GitHub-connected
Workers Build configuration; pushing alone does **not** update the public
Worker. Do not copy a broad local OAuth credential into GitHub Actions to
simulate automatic deploys. Before the holding response is replaced, finish
separate upload/compiler isolation, per-worker native runtime isolation,
Artifacts-backed shipment recovery, quotas, and end-to-end tests.
