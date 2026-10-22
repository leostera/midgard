import { DurableObject, exports as self } from "cloudflare:workers";

const origin = "https://midgard.leostera.dev";
const workerDomain = ".midgard.leostera.dev";
const backend = "http://127.0.0.1:4000";
const mediaType = "application/vnd.midgard.shipment.v1";
const maxUpload = 24_000_000;
// Demo workers removed by the operator. They are deleted, and their domains
// detached, the next time the platform restores its shipments.
const retiredWorkers = new Set([
	// The Gleam example was renamed from amber_worker to gleam_worker.
	"amber_worker_16f327441c6fc766", "amber_worker_5e8423354ac27bd9", "amber_worker_76885c9c95f26ce3",
	"amber_worker_7d8f5a5973a6cf8e", "amber_worker_7ea77a8f12d52464", "amber_worker_898bc883af7a6c56",
	"amber_worker_b3d938caa5337ab8", "amber_worker_dc6d87012e962570", "amber_worker_e9dfb376334b222c",
	// Superseded example deployments that predate GET / => "Hello Joe!".
	"erlang_worker_021a8a3f076ceb0b", "erlang_worker_39058410fca0a860", "erlang_worker_5d88f8d4c07a3841",
	"erlang_worker_80f58bf3c7bb0a20", "erlang_worker_8e7e765cd5b8f5d4", "erlang_worker_d10ea914d31ec739",
	"gleam_worker_ae647f68f90eaef3",
	// Release smoke tests.
	"hello_erlang_bb2b5867717f92c3", "hello_worker_0a6c12c4cf294489", "hello_worker_936519a46c139dc6",
	"hello_worker_a449b4ee524edc38", "hello_worker_ex_064d5579c9f280da", "hello_worker_gleam_586d4ee1a5a33c49",
	// Deploy-time measurements (scripts/measure-deploy.sh) and chunk-stripping experiments.
	"elixir_worker_11d0a8f8d10caabf", "elixir_worker_324ba6f159faeee0", "elixir_worker_357a163b4623ad5e",
	"elixir_worker_5d293b71d46fda79", "elixir_worker_a6393783095469c2", "elixir_worker_d153b5fae8c5d163",
	"erlang_worker_21c8b4dcda9b98e3", "erlang_worker_31351afe10e698b4", "erlang_worker_68ac9fce8a89e69d",
	"gleam_worker_08ded87ff8d0bd2c", "gleam_worker_0e7a2227d3e4b6f6", "gleam_worker_e4013c127b4409d8",
	// Tree-shaking prototype and stress tests, 0.4.0 measurements and smoke tests.
	"elixir_worker_2dec591bcc37beb7", "elixir_worker_66d179fb81193a67", "elixir_worker_6bfa8746d0113f3d",
	"elixir_worker_8469c9041283dbf9", "elixir_worker_daad16badc66386f", "elixir_worker_f9fcaf849f7594d9",
	"erlang_worker_7633d2cd97872fac", "erlang_worker_976b28f840d91657", "erlang_worker_b1ad17f3da357f49",
	"gleam_worker_28c06128f3b73dd8", "gleam_worker_7cbbaa588f56807d", "gleam_worker_e03e3b56e91e82fd",
	"hello_shake_257404a3ab890346", "hello_worker_c319599abb7d4137", "hello_worker_erl_94c7f7240b018e7e",
	"hello_worker_erl_bc5075541725aebd", "hello_worker_gleam_add10efbbbc9967c", "hello_worker_gleam_c9c06ad5feda61ea",
	"probe_24dcc9e9eee2b45f", "probe_b142b2f1716be0e4", "stress_worker_91c1b951a5052238",
	"stress_worker_a1b2e188d9891cbf", "stress_worker_f66ed15cc2f34542",
]);
const chunkSize = 256_000;
// Renew the ten-minute idle period for both newly started and surviving
// Containers because a DO restart loses its inactivity setting.
const inactivityMs = 10 * 60 * 1_000;
const appName = /^[a-z][a-z0-9_]{0,39}$/;
const workerName = /^[a-z][a-z0-9_]*_[0-9a-f]{16}$/;

type Saved = { slug: string; app: string; digest: string; size: number; checksum: string; domain_attached?: number };
type Chunk = { data: ArrayBuffer };

function text(message: string, status: number): Response {
	return new Response(`${message}\n`, { status, headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" } });
}

function workerHostname(slug: string): string {
	return `${slug.replaceAll("_", "-")}${workerDomain}`;
}

function workerSlug(hostname: string): string | null {
	if (!hostname.endsWith(workerDomain)) return null;
	const label = hostname.slice(0, -workerDomain.length);
	if (label.includes(".")) return null;
	const slug = label.replaceAll("-", "_");
	return workerName.test(slug) ? slug : null;
}

function hex(bytes: Uint8Array): string {
	return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function arrayBuffer(bytes: Uint8Array): ArrayBuffer {
	const copy = new Uint8Array(bytes.byteLength);
	copy.set(bytes);
	return copy.buffer;
}

async function checksum(bytes: Uint8Array): Promise<string> {
	return hex(new Uint8Array(await crypto.subtle.digest("SHA-256", arrayBuffer(bytes))));
}

async function boundedBody(request: Request): Promise<Uint8Array | null> {
	if (Number(request.headers.get("content-length")) > maxUpload || !request.body) return null;
	const reader = request.body.getReader();
	const chunks: Uint8Array[] = [];
	let size = 0;
	while (true) {
		const { value, done } = await reader.read();
		if (done) break;
		size += value.byteLength;
		if (size > maxUpload) {
			await reader.cancel();
			return null;
		}
		chunks.push(value);
	}
	if (size === 0) return null;
	const body = new Uint8Array(size);
	let position = 0;
	for (const chunk of chunks) {
		body.set(chunk, position);
		position += chunk.byteLength;
	}
	return body;
}

export class NativeRuntime extends DurableObject<Env> {
	private ready?: Promise<void>;
	private restored = false;
	private busy = false;

	constructor(ctx: DurableObjectState, env: Env) {
		super(ctx, env);
		ctx.blockConcurrencyWhile(async () => {
			const sql = ctx.storage.sql;
			sql.exec("CREATE TABLE IF NOT EXISTS shipments (slug TEXT PRIMARY KEY, app TEXT NOT NULL, digest TEXT NOT NULL, size INTEGER NOT NULL, checksum TEXT NOT NULL, active INTEGER NOT NULL, domain_attached INTEGER NOT NULL DEFAULT 0)");
			const shipmentColumns = sql.exec<{ name: string }>("PRAGMA table_info(shipments)").toArray();
			if (!shipmentColumns.some(({ name }) => name === "domain_attached")) {
				sql.exec("ALTER TABLE shipments ADD COLUMN domain_attached INTEGER NOT NULL DEFAULT 0");
			}
			sql.exec("CREATE TABLE IF NOT EXISTS chunks (slug TEXT NOT NULL, part INTEGER NOT NULL, data BLOB NOT NULL, PRIMARY KEY (slug, part))");
			sql.exec("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)");
			if (sql.exec<{ value: string }>("SELECT value FROM settings WHERE key = 'gateway'").toArray().length === 0) {
				sql.exec("INSERT INTO settings (key, value) VALUES ('gateway', ?)", hex(crypto.getRandomValues(new Uint8Array(32))));
			}
			if (ctx.container?.running) await ctx.container.setInactivityTimeout(inactivityMs);
		});
	}

	private gateway(): string {
		return this.ctx.storage.sql.exec<{ value: string }>("SELECT value FROM settings WHERE key = 'gateway'").one().value;
	}

	private async ensureReady(): Promise<void> {
		if (this.restored && !this.ctx.container?.running) {
			this.ready = undefined;
			this.restored = false;
		}
		if (!this.ready) this.ready = this.startAndRestore();
		try {
			await this.ready;
			this.restored = true;
		} catch (error) {
			this.ready = undefined;
			this.restored = false;
			throw error;
		}
	}

	private async startAndRestore(): Promise<void> {
		const container = this.ctx.container;
		if (!container) throw new Error("Platform container binding is unavailable");
		const sql = this.ctx.storage.sql;
		await this.removeRetiredWorkers();
		const saved = sql.exec<Saved>("SELECT slug, app, digest, size, checksum, domain_attached FROM shipments WHERE active = 1 ORDER BY rowid").toArray();
		// A DO eviction must not discard healthy, already-admitted Isolates. The
		// host proves the full live digest set; missing or stale handles still
		// require a fresh Container and exact shipment re-admission.
		// Durable Object containers have no rollouts: a running container keeps
		// its image across Worker deploys. Replace it when the configured image
		// changed (or was never recorded), so a new runtime image takes effect.
		const image = container.images.server;
		const startedImage = sql.exec<{ value: string }>("SELECT value FROM settings WHERE key = 'runtime_image'").toArray()[0]?.value;
		if (container.running && startedImage !== image) {
			console.log(JSON.stringify({ event: "restore_image_changed", from: startedImage ?? null, to: image }));
			await container.destroy();
		}
		if (container.running) {
			if (await this.matchesRunningHost(saved)) {
				await this.reconcileWorkerDomains(saved);
				console.log(JSON.stringify({ event: "restore_reused", count: saved.length }));
				return;
			}
			await container.destroy();
		}
		sql.exec("INSERT INTO settings (key, value) VALUES ('runtime_image', ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value", image);
		container.start({
			image,
			instance: "standard-2",
			enableInternet: false,
			env: { MIDGARD_CONTAINER_HTTP: "1", MIDGARD_INTERNAL_UPLOAD_KEY: this.gateway() },
		});
		await container.setInactivityTimeout(inactivityMs);
		const health = new Request(`${backend}/`, { headers: { host: "127.0.0.1:4000" } });
		const ready = await this.portFetch(health, true);
		if (ready.status !== 200) throw new Error("Elixir service did not start");
		sql.exec("DELETE FROM chunks WHERE slug IN (SELECT slug FROM shipments WHERE active = 0)");
		sql.exec("DELETE FROM shipments WHERE active = 0");
		console.log(JSON.stringify({ event: "restore_start", count: saved.length }));
		for (const shipment of saved) {
			const bytes = await this.readShipment(shipment);
			const response = await this.uploadToHost(shipment.app, shipment.slug, bytes);
			if (response.status !== 201) throw new Error(`Could not re-admit ${shipment.slug}: HTTP ${response.status}`);
			const admitted = await response.json() as { digest?: string; slug?: string };
			if (admitted.digest !== shipment.digest || admitted.slug !== shipment.slug) {
				throw new Error(`Stored shipment was not re-admitted: ${shipment.slug}`);
			}
			console.log(JSON.stringify({ event: "restore_admitted", slug: shipment.slug }));
		}
		await this.reconcileWorkerDomains(saved);
	}

	private async matchesRunningHost(saved: Saved[]): Promise<boolean> {
		try {
			const request = new Request(`${backend}/api/deployments/state`, {
				headers: { host: "127.0.0.1:4000", "x-midgard-internal-upload": `Bearer ${this.gateway()}` },
			});
			const response = await this.portFetch(request, false);
			if (response.status !== 200) return false;
			const live: unknown = await response.json();
			if (!Array.isArray(live) || live.length !== saved.length) return false;
			const expected = [...saved].sort((a, b) => a.slug < b.slug ? -1 : a.slug > b.slug ? 1 : 0);
			return expected.every((shipment, index) => {
				const row: unknown = live[index];
				return typeof row === "object" && row !== null && "slug" in row && "digest" in row &&
					row.slug === shipment.slug && row.digest === shipment.digest;
			});
		} catch (error) {
			console.warn("Could not verify existing Container admissions", error);
			return false;
		}
	}

	private async readShipment(saved: Saved): Promise<Uint8Array> {
		const bytes = new Uint8Array(saved.size);
		let offset = 0;
		for (const row of this.ctx.storage.sql.exec<Chunk>("SELECT data FROM chunks WHERE slug = ? ORDER BY part", saved.slug)) {
			const chunk = new Uint8Array(row.data);
			if (offset + chunk.byteLength > bytes.byteLength) throw new Error("Stored shipment length mismatch");
			bytes.set(chunk, offset);
			offset += chunk.byteLength;
		}
		if (offset !== bytes.byteLength || await checksum(bytes) !== saved.checksum) {
			throw new Error("Stored shipment checksum mismatch");
		}
		return bytes;
	}

	private async portFetch(request: Request, cold: boolean): Promise<Response> {
		const port = this.ctx.container!.getTcpPort(4000);
		for (let attempt = 0; attempt < 15; attempt++) {
			try {
				return await port.fetch(request);
			} catch (error) {
				if (!cold || attempt === 14) throw error;
				await new Promise((resolve) => setTimeout(resolve, 2_000));
			}
		}
		throw new Error("Platform did not become ready");
	}

	private async uploadToHost(app: string, route: string, body: Uint8Array): Promise<Response> {
		const request = new Request(`${backend}/api/deployments/${app}`, {
			method: "POST", body: arrayBuffer(body),
			headers: {
				"host": "127.0.0.1:4000", "content-type": mediaType,
				"x-midgard-public-route": route,
				"x-midgard-internal-upload": `Bearer ${this.gateway()}`,
			},
		});
		return this.portFetch(request, false);
	}

	private async attachWorkerDomain(hostname: string): Promise<void> {
		const response = await fetch(
			`https://api.cloudflare.com/client/v4/accounts/${this.env.CLOUDFLARE_ACCOUNT_ID}/workers/domains`,
			{
				method: "PUT",
				headers: {
					authorization: `Bearer ${this.env.CF_DNS_API_TOKEN}`,
					"content-type": "application/json",
				},
				body: JSON.stringify({
					hostname,
					service: this.env.CLOUDFLARE_WORKER_NAME,
					zone_name: "leostera.dev",
					enabled: true,
					previews_enabled: false,
				}),
			},
		);
		const result = await response.json() as {
			success?: boolean;
			result?: { hostname?: string; service?: string; enabled?: boolean };
		};
		if (!response.ok || result.success !== true || result.result?.hostname !== hostname ||
			result.result.service !== this.env.CLOUDFLARE_WORKER_NAME || result.result.enabled !== true) {
			throw new Error(`Cloudflare could not attach worker domain (HTTP ${response.status})`);
		}
	}

	private async reconcileWorkerDomains(shipments: Saved[]): Promise<void> {
		if (shipments.length === 0) return;
		const query = new URLSearchParams({
			zone_name: "leostera.dev",
			service: this.env.CLOUDFLARE_WORKER_NAME,
		});
		const response = await fetch(
			`https://api.cloudflare.com/client/v4/accounts/${this.env.CLOUDFLARE_ACCOUNT_ID}/workers/domains?${query}`,
			{ headers: { authorization: `Bearer ${this.env.CF_DNS_API_TOKEN}` } },
		);
		const result = await response.json() as {
			success?: boolean;
			result?: Array<{ hostname?: string; service?: string; enabled?: boolean }>;
		};
		if (!response.ok || result.success !== true || !Array.isArray(result.result)) {
			throw new Error(`Cloudflare could not list worker domains (HTTP ${response.status})`);
		}
		const attached = new Set(result.result
			.filter((domain) => domain.service === this.env.CLOUDFLARE_WORKER_NAME && domain.enabled === true)
			.map((domain) => domain.hostname));
		for (const shipment of shipments) {
			const hostname = workerHostname(shipment.slug);
			if (!attached.has(hostname)) await this.attachWorkerDomain(hostname);
			this.ctx.storage.sql.exec("UPDATE shipments SET domain_attached = 1 WHERE slug = ?", shipment.slug);
		}
	}

	private async deploy(request: Request, app: string): Promise<Response> {
		if (this.busy) return text("A deployment is already running; retry shortly", 429);
		if (!appName.test(app) || request.headers.get("content-type") !== mediaType || request.headers.has("origin")) {
			return text("Invalid deployment request", 400);
		}
		this.busy = true;
		console.log(JSON.stringify({ event: "deploy_start", app }));
		let route: string | undefined;
		try {
			await this.ensureReady();
			const sql = this.ctx.storage.sql;
			const bytes = await boundedBody(request);
			if (!bytes) return text("Shipment exceeds the 24 MB demo limit", 413);
			route = `${app.slice(0, 23)}_${hex(crypto.getRandomValues(new Uint8Array(8)))}`;
			const saved: Saved = { slug: route, app, digest: "", size: bytes.byteLength, checksum: await checksum(bytes) };
			sql.exec("INSERT INTO shipments (slug, app, digest, size, checksum, active) VALUES (?, ?, '', ?, ?, 0)", route, app, saved.size, saved.checksum);
			this.ctx.storage.transactionSync(() => {
				for (let offset = 0, part = 0; offset < bytes.byteLength; offset += chunkSize, part++) {
					const chunk = bytes.slice(offset, offset + chunkSize);
					sql.exec("INSERT INTO chunks (slug, part, data) VALUES (?, ?, ?)", route, part, chunk.buffer);
				}
			});
			console.log(JSON.stringify({ event: "deploy_stored", app, route, bytes: bytes.byteLength }));
			const response = await this.uploadToHost(app, route, bytes);
			console.log(JSON.stringify({ event: "deploy_admission_response", app, route, status: response.status }));
			if (response.status !== 201) {
				this.discard(route);
				return response;
			}
			const result = await response.clone().json() as { slug?: string; digest?: string };
			if (result.slug !== route || !/^[a-f0-9]{64}$/.test(result.digest ?? "")) {
				throw new Error("Platform returned an invalid admission response");
			}
			const hostname = workerHostname(route);
			await this.attachWorkerDomain(hostname);
			sql.exec("UPDATE shipments SET digest = ?, domain_attached = 1, active = 1 WHERE slug = ? AND active = 0", result.digest, route);
			return Response.json({ ...result, path: `https://${hostname}/` }, {
				status: response.status,
				headers: { "cache-control": "no-store" },
			});
		} catch (error) {
			console.error(JSON.stringify({ event: "deploy_failed", app, route, error: String(error) }));
			if (route) this.discard(route);
			// A failed publication can leave an uncommitted live handle in the
			// container; force a fresh admission from durable active shipments.
			if (this.ctx.container?.running) await this.ctx.container.destroy();
			this.ready = undefined;
			this.restored = false;
			throw error;
		} finally {
			this.busy = false;
		}
	}

	// Retired workers are deleted before restore. A surviving Container still
	// holding them no longer matches the live set, so it is replaced and only
	// the remaining shipments are re-admitted.
	private async removeRetiredWorkers(): Promise<void> {
		const sql = this.ctx.storage.sql;
		const saved = sql.exec<{ slug: string }>("SELECT slug FROM shipments").toArray();
		for (const { slug } of saved.filter((row) => retiredWorkers.has(row.slug))) {
			this.ctx.storage.transactionSync(() => {
				sql.exec("DELETE FROM chunks WHERE slug = ?", slug);
				sql.exec("DELETE FROM shipments WHERE slug = ?", slug);
			});
			console.log(JSON.stringify({ event: "worker_retired", slug }));
			await this.detachWorkerDomain(workerHostname(slug)).catch((error) => {
				console.warn(JSON.stringify({ event: "domain_detach_failed", slug, error: String(error) }));
			});
		}
	}

	private async detachWorkerDomain(hostname: string): Promise<void> {
		const api = `https://api.cloudflare.com/client/v4/accounts/${this.env.CLOUDFLARE_ACCOUNT_ID}/workers/domains`;
		const headers = { authorization: `Bearer ${this.env.CF_DNS_API_TOKEN}` };
		const query = new URLSearchParams({ zone_name: "leostera.dev", hostname, service: this.env.CLOUDFLARE_WORKER_NAME });
		const listed = await fetch(`${api}?${query}`, { headers });
		const result = await listed.json() as { success?: boolean; result?: Array<{ id?: string; hostname?: string }> };
		if (!listed.ok || result.success !== true || !Array.isArray(result.result)) {
			throw new Error(`Cloudflare could not list worker domains (HTTP ${listed.status})`);
		}
		for (const domain of result.result) {
			if (domain.hostname !== hostname || typeof domain.id !== "string") continue;
			const removed = await fetch(`${api}/${encodeURIComponent(domain.id)}`, { method: "DELETE", headers });
			if (!removed.ok) throw new Error(`Cloudflare could not detach ${hostname} (HTTP ${removed.status})`);
		}
	}

	private discard(route: string): void {
		this.ctx.storage.transactionSync(() => {
			this.ctx.storage.sql.exec("DELETE FROM chunks WHERE slug = ? AND EXISTS (SELECT 1 FROM shipments WHERE slug = ? AND active = 0)", route, route);
			this.ctx.storage.sql.exec("DELETE FROM shipments WHERE slug = ? AND active = 0", route);
		});
	}

	private publicWorker(saved: Saved) {
		return {
			slug: saved.slug,
			name: saved.app,
			url: `https://${workerHostname(saved.slug)}/`,
			digest: saved.digest,
			size: saved.size,
		};
	}

	async fetch(request: Request): Promise<Response> {
		const url = new URL(request.url);
		if (request.method === "GET" && url.pathname === "/api/workers") {
			await this.ensureReady();
			const saved = this.ctx.storage.sql
				.exec<Saved>("SELECT slug, app, digest, size, checksum FROM shipments WHERE active = 1 ORDER BY app, slug")
				.toArray();
			await this.reconcileWorkerDomains(saved);
			return Response.json({ workers: saved.map((shipment) => this.publicWorker(shipment)) }, {
				headers: { "cache-control": "no-store" },
			});
		}
		const workerMatch = url.pathname.match(/^\/api\/workers\/([a-z][a-z0-9_]*_[0-9a-f]{16})$/);
		if (request.method === "GET" && workerMatch) {
			await this.ensureReady();
			const saved = this.ctx.storage.sql
				.exec<Saved>("SELECT slug, app, digest, size, checksum FROM shipments WHERE slug = ? AND active = 1", workerMatch[1])
				.toArray()[0];
			if (!saved) return text("Worker not found", 404);
			await this.reconcileWorkerDomains([saved]);
			return Response.json(this.publicWorker(saved), { headers: { "cache-control": "no-store" } });
		}
		if (request.method === "GET" && url.pathname === "/api/deployments/ready") {
			await this.ensureReady();
			const saved = this.ctx.storage.sql
				.exec<Saved>("SELECT slug, app, digest, size, checksum FROM shipments WHERE active = 1")
				.toArray();
			await this.reconcileWorkerDomains(saved);
			return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
		}
		if (request.method === "POST" && url.pathname.startsWith("/api/deployments/")) {
			return this.deploy(request, url.pathname.slice("/api/deployments/".length));
		}
		if (this.busy && (url.pathname === "/" || url.pathname.startsWith("/workers/"))) return text("Inventory is updating", 503);
		const run = url.pathname.match(/^\/run\/([a-z][a-z0-9_]*_[0-9a-f]{16})(?:\/|$)/);
		if (run && !this.ctx.storage.sql.exec("SELECT 1 FROM shipments WHERE slug = ? AND active = 1", run[1]).toArray().length) {
			return text("Worker not found", 404);
		}
		await this.ensureReady();
		const upstream = new Request(`${backend}${url.pathname}${url.search}`, request);
		upstream.headers.set("host", "127.0.0.1:4000");
		for (const name of ["authorization", "cookie", "x-midgard-internal-upload", "x-midgard-public-route"]) {
			upstream.headers.delete(name);
		}
		return this.portFetch(upstream, false);
	}
}

type EmailBinding = { send(message: { from: string; to: string; subject: string; text: string; html: string }): Promise<unknown> };
type AccountEnv = Env & { EMAIL: EmailBinding };

async function sha256(value: string): Promise<string> {
	return hex(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))));
}

function json(data: unknown, status = 200, headers: HeadersInit = {}): Response {
	return Response.json(data, { status, headers: { "cache-control": "no-store", ...Object.fromEntries(new Headers(headers)) } });
}

// Per-account state is isolated by deterministic email hash. Only code and
// session hashes are stored; raw credentials are returned once to the client.
export class Account extends DurableObject<AccountEnv> {
	constructor(ctx: DurableObjectState, env: AccountEnv) {
		super(ctx, env);
		ctx.blockConcurrencyWhile(async () => {
			ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS account (email TEXT NOT NULL)");
			ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS login_code (hash TEXT NOT NULL, expires INTEGER NOT NULL, attempts INTEGER NOT NULL, sent_at INTEGER NOT NULL)");
			ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS sessions (hash TEXT PRIMARY KEY, expires INTEGER NOT NULL, client TEXT NOT NULL)");
		});
	}

	async fetch(request: Request): Promise<Response> {
		const url = new URL(request.url);
		const sql = this.ctx.storage.sql;
		if (request.method === "POST" && url.pathname === "/start") {
			const { email } = await request.json() as { email?: string };
			const normalized = email?.trim().toLowerCase();
			if (!normalized || normalized.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(normalized)) return json({ error: "invalid_email" }, 400);
			const now = Date.now();
			const previous = sql.exec<{ sent_at: number }>("SELECT sent_at FROM login_code").toArray()[0];
			if (previous && now - previous.sent_at < 60_000) return json({ error: "try_later" }, 429);
			const code = String(crypto.getRandomValues(new Uint32Array(1))[0]! % 1_000_000).padStart(6, "0");
			sql.exec("DELETE FROM login_code");
			sql.exec("INSERT INTO login_code (hash, expires, attempts, sent_at) VALUES (?, ?, 0, ?)", await sha256(code), now + 600_000, now);
			sql.exec("DELETE FROM account");
			sql.exec("INSERT INTO account (email) VALUES (?)", normalized);
			try {
				await this.env.EMAIL.send({
					from: "login@midgard.leostera.dev", to: normalized, subject: "Your Midgard sign-in code",
					text: `Your Midgard sign-in code is ${code}. It expires in 10 minutes. If you did not request this, you can ignore this email.`,
					html: `<p>Your Midgard sign-in code is:</p><p style="font-size:28px;font-weight:bold;letter-spacing:0.2em">${code}</p><p>It expires in 10 minutes. If you did not request this, you can ignore this email.</p>`,
				});
			} catch (error) {
				sql.exec("DELETE FROM login_code");
				console.error("login_email_failed", String(error));
				return json({ error: "email_unavailable" }, 503);
			}
			return json({ ok: true });
		}
		if (request.method === "POST" && url.pathname === "/verify") {
			const { code, client } = await request.json() as { code?: string; client?: string };
			const saved = sql.exec<{ hash: string; expires: number; attempts: number }>("SELECT hash, expires, attempts FROM login_code").toArray()[0];
			if (!saved || saved.expires < Date.now() || saved.attempts >= 5 || !/^\d{6}$/.test(code ?? "")) return json({ error: "invalid_code" }, 401);
			if (await sha256(code!) !== saved.hash) {
				sql.exec("UPDATE login_code SET attempts = attempts + 1");
				return json({ error: "invalid_code" }, 401);
			}
			const account = sql.exec<{ email: string }>("SELECT email FROM account").toArray()[0];
			if (!account) return json({ error: "invalid_code" }, 401);
			sql.exec("DELETE FROM login_code");
			const secret = hex(crypto.getRandomValues(new Uint8Array(32)));
			const expiry = Date.now() + (client === "cli" ? 90 : 30) * 86_400_000;
			sql.exec("INSERT INTO sessions (hash, expires, client) VALUES (?, ?, ?)", await sha256(secret), expiry, client === "cli" ? "cli" : "web");
			return json({ email: account.email, token: secret, expires: expiry });
		}
		if (request.method === "POST" && url.pathname === "/auth") {
			const { token, revoke } = await request.json() as { token?: string; revoke?: boolean };
			if (!token || !/^[a-f0-9]{64}$/.test(token)) return json({ error: "unauthorized" }, 401);
			const hash = await sha256(token);
			const saved = sql.exec<{ expires: number }>("SELECT expires FROM sessions WHERE hash = ?", hash).toArray()[0];
			if (!saved || saved.expires < Date.now()) return json({ error: "unauthorized" }, 401);
			if (revoke) { sql.exec("DELETE FROM sessions WHERE hash = ?", hash); return json({ ok: true }); }
			const account = sql.exec<{ email: string }>("SELECT email FROM account").toArray()[0];
			return account ? json({ email: account.email, expires: saved.expires }) : json({ error: "unauthorized" }, 401);
		}
		return json({ error: "not_found" }, 404);
	}
}

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		const url = new URL(request.url);
		const mainHost = url.origin === origin;
		const slug = workerSlug(url.hostname);
		const isWorkerHost = url.protocol === "https:" && slug !== null;
		const app = url.pathname.startsWith("/api/deployments/") ? url.pathname.slice("/api/deployments/".length) : null;
		const isUpload = mainHost && request.method === "POST" && app !== null && appName.test(app) && !url.search;
		const isReady = mainHost && request.method === "GET" && url.pathname === "/api/deployments/ready" && !url.search;
		const isFrontend = mainHost && request.method === "GET" &&
			(url.pathname === "/" || url.pathname === "/login" || url.pathname === "/dashboard" || url.pathname === "/workers" || /^\/workers\/[a-z][a-z0-9_]*_[0-9a-f]{16}$/.test(url.pathname));
		const isAsset = mainHost && request.method === "GET" && url.pathname.startsWith("/assets/");
		const isWorkerRead = mainHost && request.method === "GET" && /^\/api\/workers(?:\/[a-z][a-z0-9_]*_[0-9a-f]{16})?$/.test(url.pathname) && !url.search;
		const isAuth = mainHost && ["/api/login/start", "/api/login/verify", "/api/logout", "/api/me"].includes(url.pathname);
		const isCall = isWorkerHost && ["GET", "POST", "PUT", "DELETE", "PATCH"].includes(request.method);
		if ((!mainHost && !isWorkerHost) || (!isUpload && !isReady && !isWorkerRead && !isAuth && !isCall && !isFrontend && !isAsset)) {
			return text("Not found", 404);
		}
		const ip = request.headers.get("cf-connecting-ip");
		if (!ip) return text("Forbidden", 403);
		const { success } = await env.HTTP_RATE.limit({ key: ip });
		if (!success) return text("Too many requests", 429);
		if (isAuth) {
			const requestOrigin = request.headers.get("origin");
			if (requestOrigin && requestOrigin !== origin) return json({ error: "forbidden" }, 403);
			if ((url.pathname === "/api/me" && request.method !== "GET") || (url.pathname === "/api/logout" && request.method !== "POST") || (!url.pathname.endsWith("/me") && url.pathname !== "/api/logout" && request.method !== "POST")) return text("Not found", 404);
			if (url.pathname === "/api/login/start") {
				const limit = await env.LOGIN_RATE.limit({ key: ip });
				if (!limit.success) return json({ error: "try_later" }, 429);
				try {
					const data = await request.json() as { email?: string };
					const key = await sha256(data.email?.trim().toLowerCase() ?? "");
					return await self.Account.getByName(key).fetch(new Request("https://account/start", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(data) }));
				} catch { return json({ error: "invalid_request" }, 400); }
			}
			if (url.pathname === "/api/login/verify") {
				try {
					const data = await request.json() as { email?: string; code?: string; client?: string };
					const email = data.email?.trim().toLowerCase() ?? "";
					if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || !["web", "cli"].includes(data.client ?? "")) return json({ error: "invalid_request" }, 400);
					const key = await sha256(email);
					const result = await self.Account.getByName(key).fetch(new Request("https://account/verify", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(data) }));
					if (!result.ok) return result;
					const payload = await result.json() as { email: string; token: string; expires: number };
					const headers = new Headers({ "cache-control": "no-store" });
					if (data.client === "cli") return json({ ...payload, token: `${key}.${payload.token}` });
					headers.set("set-cookie", `__Host-midgard_session=${key}.${payload.token}; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=2592000`);
					return json({ email: payload.email }, 200, headers);
				} catch { return json({ error: "invalid_request" }, 400); }
			}
			const authorization = request.headers.get("authorization")?.match(/^Bearer ([a-f0-9]{64}(?:\.[a-f0-9]{64})?)$/)?.[1];
			const cookie = request.headers.get("cookie")?.match(/(?:^|;\s*)__Host-midgard_session=([a-f0-9]{64})\.([a-f0-9]{64})(?:;|$)/);
			const token = authorization ? null : cookie?.[2];
			const key = authorization ? "" : cookie?.[1];
			let accountKey = key;
			let secret = token;
			if (authorization) {
				const parts = authorization.split(".");
				if (parts.length !== 2 || !/^[a-f0-9]{64}$/.test(parts[0]!) || !/^[a-f0-9]{64}$/.test(parts[1]!)) return json({ error: "unauthorized" }, 401);
				[accountKey, secret] = parts;
			}
			if (url.pathname === "/api/logout") {
				if (accountKey && secret) await self.Account.getByName(accountKey).fetch(new Request("https://account/auth", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ token: secret, revoke: true }) }));
				return new Response(null, { status: 204, headers: { "set-cookie": "__Host-midgard_session=; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=0", "cache-control": "no-store" } });
			}
			if (!accountKey || !secret) return json({ error: "unauthorized" }, 401);
			return self.Account.getByName(accountKey).fetch(new Request("https://account/auth", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ token: secret }) }));
		}
		if (isUpload) {
			const build = await env.DEPLOY_RATE.limit({ key: ip });
			if (!build.success) return text("Too many deployments", 429);
		}
		if (isFrontend || isAsset) {
			const assetRequest = isFrontend ? new Request(new URL("/", request.url), request) : request;
			const response = await env.ASSETS.fetch(assetRequest);
			const headers = new Headers(response.headers);
			headers.set("cache-control", isFrontend ? "no-store" : "public, max-age=31536000, immutable");
			headers.set("x-content-type-options", "nosniff");
			return new Response(response.body, { status: response.status, headers });
		}
		try {
			// Public worker hostnames are immutable aliases for the internal route
			// slug. Keep /run out of the public URL surface.
			const upstream = isReady
				? new Request(`${origin}/`, request)
				: isCall
					? new Request(`${origin}/run/${slug}${url.pathname}${url.search}`, request)
					: request;
			const response = await self.NativeRuntime.getByName("platform").fetch(upstream);
			if (isReady && [200, 204].includes(response.status)) {
				await response.body?.cancel();
				return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
			}
			const headers = new Headers(response.headers);
			headers.set("cache-control", "no-store");
			headers.set("x-content-type-options", "nosniff");
			return new Response(response.body, { status: response.status, headers });
		} catch (error) {
			console.error("Elixir platform unavailable", error);
			return text("Platform temporarily unavailable", 503);
		}
	},
} satisfies ExportedHandler<Env>;
