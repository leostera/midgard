import { DurableObject, exports as self } from "cloudflare:workers";

const origin = "https://midgard.leostera.dev";
const backend = "http://127.0.0.1:4000";
const mediaType = "application/vnd.midgard.shipment.v1";
const maxUpload = 24_000_000;
const maxWorkers = 32;
const chunkSize = 256_000;
// Renew the ten-minute idle period for both newly started and surviving
// Containers because a DO restart loses its inactivity setting.
const inactivityMs = 10 * 60 * 1_000;
const publicGets = new Set(["/", "/workers/new", "/assets/app.css", "/assets/favicon.svg"]);
const appName = /^[a-z][a-z0-9_]{0,39}$/;
const workerName = /^[a-z][a-z0-9_]*_[0-9a-f]{16}$/;

type Saved = { slug: string; app: string; digest: string; size: number; checksum: string };
type Chunk = { data: ArrayBuffer };

function text(message: string, status: number): Response {
	return new Response(`${message}\n`, { status, headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" } });
}

function hex(bytes: Uint8Array): string {
	return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function checksum(bytes: Uint8Array): Promise<string> {
	return hex(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)));
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
			sql.exec("CREATE TABLE IF NOT EXISTS shipments (slug TEXT PRIMARY KEY, app TEXT NOT NULL, digest TEXT NOT NULL, size INTEGER NOT NULL, checksum TEXT NOT NULL, active INTEGER NOT NULL)");
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
		const saved = sql.exec<Saved>("SELECT slug, app, digest, size, checksum FROM shipments WHERE active = 1 ORDER BY rowid").toArray();
		// A DO eviction must not discard healthy, already-admitted Isolates. The
		// host proves the full live digest set; missing or stale handles still
		// require a fresh Container and exact shipment re-admission.
		if (container.running) {
			if (await this.matchesRunningHost(saved)) {
				console.log(JSON.stringify({ event: "restore_reused", count: saved.length }));
				return;
			}
			await container.destroy();
		}
		container.start({
			image: container.images.server,
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
			method: "POST", body,
			headers: {
				"host": "127.0.0.1:4000", "content-type": mediaType,
				"x-midgard-public-route": route,
				"x-midgard-internal-upload": `Bearer ${this.gateway()}`,
			},
		});
		return this.portFetch(request, false);
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
			if (sql.exec<{ n: number }>("SELECT count(*) AS n FROM shipments WHERE active = 1").one().n >= maxWorkers) {
				return text("Demo deployment capacity reached", 429);
			}
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
			sql.exec("UPDATE shipments SET digest = ?, active = 1 WHERE slug = ? AND active = 0", result.digest, route);
			return response;
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

	private discard(route: string): void {
		this.ctx.storage.transactionSync(() => {
			this.ctx.storage.sql.exec("DELETE FROM chunks WHERE slug = ? AND EXISTS (SELECT 1 FROM shipments WHERE slug = ? AND active = 0)", route, route);
			this.ctx.storage.sql.exec("DELETE FROM shipments WHERE slug = ? AND active = 0", route);
		});
	}

	async fetch(request: Request): Promise<Response> {
		const url = new URL(request.url);
		if (request.method === "GET" && url.pathname === "/api/deployments/ready") {
			await this.ensureReady();
			return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
		}
		if (request.method === "POST" && url.pathname.startsWith("/api/deployments/")) {
			return this.deploy(request, url.pathname.slice("/api/deployments/".length));
		}
		if (this.busy && (url.pathname === "/" || url.pathname.startsWith("/workers/"))) return text("Inventory is updating", 503);
		await this.ensureReady();
		const upstream = new Request(`${backend}${url.pathname}${url.search}`, request);
		upstream.headers.set("host", "127.0.0.1:4000");
		for (const name of ["authorization", "cookie", "x-midgard-internal-upload", "x-midgard-public-route"]) {
			upstream.headers.delete(name);
		}
		return this.portFetch(upstream, false);
	}
}

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		const url = new URL(request.url);
		const app = url.pathname.startsWith("/api/deployments/") ? url.pathname.slice("/api/deployments/".length) : null;
		const isUpload = request.method === "POST" && app !== null && appName.test(app) && !url.search;
		const isReady = request.method === "GET" && url.pathname === "/api/deployments/ready" && !url.search;
		const isDetail = request.method === "GET" && /^\/workers\/[a-z][a-z0-9_]{0,39}$/.test(url.pathname);
		const isCall = url.pathname.startsWith("/run/") && /^\/run\/[a-z][a-z0-9_]{0,39}\/.*$/.test(url.pathname) && ["GET", "POST", "PUT", "DELETE", "PATCH"].includes(request.method);
		if (url.origin !== origin || (!isUpload && !isReady && !isCall && !isDetail && !(request.method === "GET" && publicGets.has(url.pathname)))) {
			return text("Not found", 404);
		}
		const ip = request.headers.get("cf-connecting-ip");
		if (!ip) return text("Forbidden", 403);
		const { success } = await env.HTTP_RATE.limit({ key: ip });
		if (!success) return text("Too many requests", 429);
		if (isUpload) {
			const build = await env.DEPLOY_RATE.limit({ key: ip });
			if (!build.success) return text("Too many deployments", 429);
		}
		try {
			// Older DO instances can stay alive across edge deployments. Use the
			// always-supported inventory path as the readiness probe as well.
			const upstream = isReady ? new Request(`${origin}/`, request) : request;
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
