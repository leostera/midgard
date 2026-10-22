# RFD0004 - Accounts, stable worker URLs and a dashboard

- Feature Name: `midgard-accounts`
- Status: Draft
- Author: Leandro Ostera
- Start Date: 2026-10-21
- Updated: 2026-10-21

## Summary

Let people sign in with their email address, see their workers on a dashboard, and update a worker in place. A worker gets a random URL once, `<name>-<random>.midgard.leostera.dev`, and every later deploy of that worker serves from the same URL. Sign-in sends a one-time code with Cloudflare Email Service. Each account is a Durable Object that owns its sessions, CLI tokens and workers. The existing platform Durable Object keeps sole ownership of shipments and routing. Each version is still admitted once under its own internal slug, and the worker's hostname points at its current version. The CLI signs in with the same email code and deploys with a token. Anonymous deploys keep working as they do today.

## Motivation

Today every deploy is anonymous and gets a new immutable URL (`sites/midgard.leostera.dev/src/index.ts`, `deploy`):

- **You can't update a worker.** Fixing a typo produces a new URL, so every link to the old one serves stale code forever.
- **Every deploy waits for DNS.** The new hostname needs a DNS record and a certificate. That's 5–11 s of the 15 s it takes an Elixir worker to go live (`bench/README.md`). It also sets a trap: a resolver asked too early caches "not found" for up to 30 minutes.
- **Nobody owns anything.** You can't list, delete or roll back your workers. The only cleanup is the operator's `retiredWorkers` list, and every retirement restarts the platform container.
- **There's nowhere to put per-user features** such as logs, limits or secrets.

## Goals

- Sign in with email from the website and from the CLI.
- A stable URL per worker, assigned on the first deploy and reused by every update.
- Updates go live without a DNS wait, and without any moment where the URL serves nothing or a half-loaded version.
- A dashboard for your workers: their versions, URLs and sizes, plus rolling back and deleting.
- Anonymous deploys keep working unchanged.

## Non-goals

- Passwords, OAuth providers, teams or organizations.
- Custom domains.
- Logs and metrics in the dashboard. They're the obvious next feature, but libbeam doesn't surface useful errors yet.
- Secrets or environment variables for workers.
- Billing and quotas beyond rate limits.
- Removing the single platform container (a separate problem).

## Guide-level explanation

### Signing in on the website

Select **Sign in** and enter your email address. Midgard emails you a six-digit code from `login@midgard.leostera.dev`. Enter it and you land on `/dashboard`. There's no sign-up step: the first code you confirm creates your account.

### Deploying from the CLI

```sh
$ mix midgard.login
Email: joe@example.com
We sent a code to joe@example.com.
Code: 482913
Signed in as joe@example.com.

$ mix midgard.deploy
Shaken: 414 → 177 modules, 23249 → 3510 functions, 18.8 MB → 1.5 MB
Deployed hello_worker v1 · 177 BEAMs
Worker URL: https://hello-worker-7f3a9c21b04de855.midgard.leostera.dev/

# edit lib/hello_worker.ex, then:
$ mix midgard.deploy
Updated hello_worker to v2 (was v1)
Worker URL: https://hello-worker-7f3a9c21b04de855.midgard.leostera.dev/
```

The second deploy reuses the URL, which already resolves and has a certificate, so it's live as soon as libbeam admits the new version. `rebar3 midgard login` and `rebar3 midgard deploy` work the same way and share the stored credentials. Gleam projects already deploy with `mix midgard.deploy --artifact`.

A worker is identified by its name within your account: the Mix app name, or the rebar3 entry application. Deploying `hello_worker` again updates your `hello_worker`, from any machine you're signed in on. `mix midgard.deploy --new` creates another worker with a fresh URL. Without signing in, `mix midgard.deploy` behaves as it does today: a fresh, unowned, immutable URL for every deploy.

### The dashboard

`/dashboard` lists your workers: name, URL, current version, size and when it was deployed. A worker's page lists its versions. From there you can:

- **Roll back:** make an earlier version current again. The URL switches once that version is admitted.
- **Delete** the worker. Its URL stops answering, and the name becomes free again.
- **Copy** the URL or a `curl` command.

The dashboard uses [Kumo](https://kumo-ui.com): Table, Badge, Dialog, Empty and Clipboard Text. The landing page keeps its own styles.

## Reference-level explanation

### Components and ownership

```text
Browser / CLI
   │
   ▼
Edge Worker (index.ts) ── sessions/tokens ──► Account DO (one per email)
   │                                             │ owns: sessions, CLI tokens,
   │                                             │ workers, versions (metadata)
   │  shipments, routing                         ▼
   └──────────────────────────────────────► Platform DO ("platform")
                                               │ owns: shipment bytes, admission,
                                               │ worker → current version routing
                                               ▼
                                           Elixir platform + libbeam (container)
```

- **Account DO** (new class, SQLite storage): one instance per account, named by `getByName("account:" + normalizedEmail)`. It holds the login code state, sessions, CLI tokens, and the account's workers and their version history. It never stores shipment bytes.
- **Platform DO** (the existing `NativeRuntime`): still the only owner of shipment bytes, of admission, and of which version a hostname serves. Every worker request already goes through it, so routing stays there.
- **Elixir platform:** unchanged. It keeps admitting each internal slug exactly once (`Deployments.deploy/3` returns `:already_deployed` for a known slug). Updates never replace modules under a live slug.

Sessions must reach the right Account DO without a lookup table. A session or CLI token has the form `<account-id>.<secret>`, where `<account-id>` is the hex Durable Object id (`idFromName(...).toString()`). The edge routes it with `idFromString(accountId)`. The DO stores only `SHA-256(secret)` and compares in constant time. The token never contains the email address.

### Names, URLs and versions

- **Worker:** `(account, name)`. Its public slug is `<name>_<16 hex>`, assigned randomly on the first deploy and never changed. That's the same format as today, so `workerHostname`, `workerSlug` and the domain-attach code need no changes.
- **Version:** an immutable shipment. Its internal slug is a fresh `<name>_<16 hex>` per deploy, used only between the Platform DO and the Elixir platform. Versions are numbered `v1, v2, …` per worker.
- **Anonymous deploy:** the public slug and the internal slug are the same, exactly as today.

The Platform DO's `shipments` table gains a `worker` column (public slug) and a `current` flag. Requests to a public hostname resolve `worker → current internal slug` before forwarding to `/run/<internal>`.

### Deploy and update flow

1. The CLI sends `POST /api/deployments/<name>` with `Authorization: Bearer <token>` (and `?new=1` for `--new`).
2. The edge authenticates the token against the Account DO. The Account DO returns the worker's public slug, assigning a new one if the name is new, plus the next version number.
3. The edge forwards the shipment to the Platform DO with the public slug and the new internal slug.
4. The Platform DO stores the chunks, and the Elixir platform admits the internal slug as today.
5. **Only after admission succeeds**, the Platform DO flips `current` to the new version in one transaction. It then stops the previous version's isolate and keeps its chunks.
6. The Account DO records the version. If this step fails after the flip, the Platform DO is the source of truth, and the Account DO reconciles from it on the next read.
7. The domain is attached only on a worker's first version. Updates skip DNS entirely.

**Failure:** if admission fails, `current` doesn't change, the new chunks are discarded, and the old version keeps serving. This is the same guarantee anonymous deploys have today.

**Rollback** re-admits a stored earlier version under a new internal slug, so a slug is never admitted twice, then flips `current`. It takes about as long as a deploy without the upload, a few seconds.

**Retention:** a worker keeps its last 5 versions' bytes. Older ones keep their metadata but lose their bytes and can't be rolled back to. Only the current version is admitted, so only the current version is re-admitted after a container restart.

**Deleting** removes the routing, stops the isolate, deletes all chunks, and detaches the domain. Then the Account DO forgets the worker. Deletes are applied directly, so the operator's `retiredWorkers` list is only needed for anonymous workers.

### Email sign-in

Sign-in has three endpoints:

- `POST /api/login/start {email, turnstileToken}` (website) or `{email}` (CLI, which gets a stricter rate limit).
  - The edge verifies Turnstile and rate-limits per IP.
  - The Account DO enforces at most 3 codes per 15 minutes per address.
  - It stores `SHA-256(code)` with a 10-minute expiry and 5 attempts, and sends the code with the `send_email` binding.
  - The response is the same whether or not the account exists.
- `POST /api/login/verify {email, code, client: "web" | "cli"}`. Success clears the code.
  - Web: sets a `__Host-midgard_session` cookie (Secure, HttpOnly, SameSite=Lax, 30 days).
  - CLI: returns a token (90 days, revocable from the dashboard).
- `POST /api/logout` revokes the current session or token.

Email addresses are normalized by trimming and lowercasing (no Gmail dot or plus folding). Six digits with 5 attempts and a 10-minute expiry gives a 1 in 200,000 guess chance per code. With per-address issuance limits, that's acceptable for this threat model.

Sending requires onboarding a sending domain to Email Service: `midgard.leostera.dev`, which Email Sending treats as its own domain. Mail is sent from `login@midgard.leostera.dev`, with both text and HTML bodies.

### CLI credentials

- **Mix:** `mix midgard.login` stores `{endpoint, token, email}` in `:filename.basedir(:user_config, "midgard")/credentials.json` with mode `0600`. `MIDGARD_DEPLOY_TOKEN` still takes precedence, so CI can deploy without a file.
- **rebar3:** `rebar3 midgard login` writes the same file, and `rebar3 midgard deploy` reads it.
- **Logging out:** `mix midgard.logout` revokes the token and deletes the file.

### API

All routes are on `midgard.leostera.dev`. Session-authenticated routes require the cookie and reject cross-site requests (`Origin` must match). Token-authenticated routes require `Authorization`.

| Route | Auth | Purpose |
|---|---|---|
| `POST /api/login/start`, `/api/login/verify`, `/api/logout` | none / session | sign in, sign out |
| `GET /api/me` | session or token | email, worker count |
| `GET /api/me/workers` | session or token | workers with current versions |
| `GET /api/me/workers/<slug>` | session or token | versions |
| `POST /api/me/workers/<slug>/rollback {version}` | session or token | make a version current |
| `DELETE /api/me/workers/<slug>` | session or token | delete |
| `GET /api/me/tokens`, `DELETE /api/me/tokens/<id>` | session | list and revoke CLI tokens |
| `POST /api/deployments/<name>` | optional token | deploy; with a token, create or update |

The public `/api/workers` listing keeps showing only the operator's demos. Owned workers aren't listed publicly, though their URLs stay public.

### Invariants

1. An internal slug is admitted at most once. Updates and rollbacks always use a fresh internal slug.
2. A public hostname serves either the previous current version or the new one, never a partially admitted version, and never nothing because of an update.
3. Shipment bytes live only in the Platform DO. The Account DO holds metadata and hashes.
4. No secret is stored in plaintext: codes, sessions and tokens are stored as SHA-256 hashes.
5. A session or token can only act on workers in its own account. The Platform DO accepts an update for a public slug only if the edge passes the owning account id, and that matches the id recorded with the worker.
6. Anonymous deploys behave exactly as before.

### Abuse and limits

- **Sign-in:** Turnstile on the website form, per-IP rate limits for start and verify, and per-address issuance limits. Email Service's daily quota is the backstop.
- **Deploys:** the existing 2-per-minute-per-IP limit stays. Signed-in accounts also get a per-account limit, and at most 20 workers per account in the demo.
- **Storage:** with 5 versions at about 1.5 MB each for shaken Elixir workers, a full account (20 workers) uses about 150 MB in the Platform DO. A SQLite-backed Durable Object holds up to 10 GB, so one Platform DO fits roughly 65 full accounts. Most accounts won't be full, but this is the first hard limit we'll hit (see Drawbacks).

## Implementation plan

1. **Stable workers in the Platform DO.** Add the `worker` and `current` columns, route hostnames through `current`, flip only after admission, add retention, and make rollback and delete internal methods. Add tests in `src/index.test.ts`, and migrate existing rows so `worker = slug` and `current = 1`.
2. **Account DO and email sign-in.** Add the new class and migration, the `send_email` binding, Turnstile, the `/api/login/*` routes and sessions. Onboard `midgard.leostera.dev` to Email Sending, which needs the user's dashboard access.
3. **CLI.** `mix midgard.login` / `logout`, the credentials file, token deploys and `--new`; the same in `rebar3_midgard`. Released as 0.5.0 for all six packages.
4. **Dashboard.** `/dashboard` routes with Kumo (`@cloudflare/kumo`, standalone CSS, loaded only on dashboard routes), backed by the `/api/me/*` routes.
5. **Docs and site.** Update the README quickstart with an optional `login` step, and add a "Sign in" link in the header.

Steps 1 and 2 ship to production behind no flag. They're backward compatible, because nothing uses them until the CLI does.

## Drawbacks

- **One Platform DO still holds everything.** Version history multiplies the storage per worker, and a platform container restart (a runtime image change, a crash, or retiring anonymous workers) still takes every worker down for about a minute while they're re-admitted. Accounts make that outage more visible, since people now have workers they care about.
- **Email is a dependency of signing in.** If mail is delayed or lands in spam, people can't sign in. There's no fallback.
- **Name-based updates can surprise people.** Two different projects called `hello_worker` in the same account update the same worker. `--new` and the dashboard make it visible, but not impossible.
- **More surface to secure.** Cookies, tokens and an email-sending endpoint are all new attack surface for a demo.

## Rationale and alternatives

- **D1 for accounts instead of a DO per account.** D1 would make cross-account queries easy, but we don't need any. A DO per account gives strongly consistent per-user state, natural isolation, and routing by id without an index. Sessions route by the id embedded in the token.
- **Replacing modules under a live slug.** This would avoid internal slugs, but it breaks the platform's admit-once invariant and libbeam's group admission. A failed update could leave a worker half-replaced.
- **Username in the hostname** (`<name>-<random>.<user>.midgard.leostera.dev`). Rejected: usernames become permanent, renaming an account would break URLs, and it rules out a one-level wildcard certificate later.
- **A project-local deploy token instead of accounts.** Storing a per-worker secret in the project would give updates without accounts, but no dashboard, nothing across machines, and easy loss. It's still a reasonable stepping stone if accounts slip.
- **Cloudflare Access with one-time PIN.** No code to write, but Access is built for workforce users, not a public developer product, and its free tier caps seats.
- **Magic links instead of codes.** Codes work the same in a terminal and in a browser, and on a different device than the one you signed in from.
- **Doing nothing.** Midgard stays a one-shot demo. That's fine for the announcement, but nobody can keep a worker.

## Prior art

- **Vercel, Netlify, Fly.io:** each deploy is an immutable version, and a stable alias points at the current one. Rollback repoints the alias. Midgard's internal slug and stable public slug follow the same model.
- **`fly auth login`, `wrangler login`, `gh auth login`:** the CLI gets a revocable token stored in a per-user config file. This RFD uses email codes instead of an OAuth browser flow, because there's no identity provider.
- **Slack, Notion:** six-digit email codes for passwordless sign-in, which also work across devices.

## Unresolved questions

### Before acceptance

- Should worker names be unique per account (proposed), or should projects pin a worker slug in a file, so two `hello_worker` projects don't collide?
- Should anonymous deploys stay forever, or eventually require signing in? This proposal keeps them.
- Is 5 versions with bytes the right retention?

### During implementation

- Should sessions be cached at the edge to save an Account DO round trip, and if so, how should revocation reach the cache?
- What's the email copy, and is a branded HTML template worth it?
- Should Kumo's standalone CSS be lazy-loaded on dashboard routes only, to keep the landing page bundle small?

### Out of scope

- Logs, metrics, secrets, custom domains, teams and billing.

## Future possibilities

- **Logs:** per-worker request and error logs in the dashboard, once libbeam reports structured errors.
- **Wildcard routing:** a one-level wildcard on `midgard.leostera.dev` would remove the DNS wait from first deploys too.
- **Per-account placement:** with accounts as the unit, the platform could eventually shard containers per account instead of running one container for everyone.
- **Preview versions:** deploying without making the version current, served at a per-version URL.
