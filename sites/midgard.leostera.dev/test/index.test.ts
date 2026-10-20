import { expect, mock, test } from "bun:test";
import { Database } from "bun:sqlite";

const state = { calls: 0, assets: [] as string[], upstream: [] as string[], limited: false, buildsLimited: false };
const domainRequests: Array<{ url: string; body: Record<string, unknown> }> = [];
const attachedDomains = new Set<string>();
globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
	const url = input instanceof Request ? input.url : input instanceof URL ? input.href : input;
	if ((init?.method ?? "GET") === "GET") {
		return Response.json({
			success: true,
			result: [...attachedDomains].map((hostname) => ({ hostname, service: "midgard-leostera-dev", enabled: true })),
		});
	}
	const body = JSON.parse(String(init?.body)) as Record<string, unknown>;
	domainRequests.push({ url, body });
	attachedDomains.add(String(body.hostname));
	return Response.json({
		success: true,
		result: { hostname: body.hostname, service: "midgard-leostera-dev", enabled: true },
	});
}) as typeof fetch;
mock.module("cloudflare:workers", () => ({
	DurableObject: class {
		ctx: unknown;
		env: unknown;
		constructor(ctx: unknown, env: unknown) { this.ctx = ctx; this.env = env; }
	},
	exports: {
		NativeRuntime: {
			getByName(name: string) {
				expect(name).toBe("platform");
				return { fetch: async (request: Request) => {
					state.calls++;
					state.upstream.push(request.url);
					return new Response("<h1>Workers</h1>", { headers: { "content-type": "text/html" } });
				} };
			},
		},
	},
}));
const { default: worker, NativeRuntime } = await import("../src/index.ts");
const env = {
	ASSETS: { fetch: async (request: Request) => {
		state.assets.push(new URL(request.url).pathname);
		return new Response("<!doctype html><h1>Midgard</h1>", { headers: { "content-type": "text/html" } });
	} },
	HTTP_RATE: { limit: async () => ({ success: !state.limited }) },
	DEPLOY_RATE: { limit: async () => ({ success: !state.buildsLimited }) },
	CLOUDFLARE_ACCOUNT_ID: "test-account",
	CF_DNS_API_TOKEN: "test-token",
	CLOUDFLARE_WORKER_NAME: "midgard-leostera-dev",
} as unknown as Env;
const visit = (path: string, method = "GET", headers: Record<string, string> = {}) => new Request(`https://midgard.leostera.dev${path}`, {
	method,
	headers: { "cf-connecting-ip": "192.0.2.1", ...headers },
});

function runtimeHarness() {
	const db = new Database(":memory:");
	const requests: Request[] = [];
	let starts = 0;
	let destroys = 0;
	let timeouts = 0;
	const admitted = new Map<string, string>();
	const container = {
		running: false,
		images: { server: "midgard-runtime@sha256:example" },
		start(options: { env: Record<string, string>; instance: string }) {
			expect(options.instance).toBe("standard-2");
			expect(options.env.MIDGARD_INTERNAL_UPLOAD_KEY.length).toBe(64);
			this.running = true;
			admitted.clear();
			starts++;
		},
		async destroy() { destroys++; this.running = false; admitted.clear(); },
		async setInactivityTimeout(value: number) { expect(value).toBe(600_000); timeouts++; },
		getTcpPort(port: number) {
			expect(port).toBe(4000);
			return { fetch: async (request: Request) => {
				requests.push(request);
				const url = new URL(request.url);
				if (url.pathname === "/api/deployments/state") {
					if (!request.headers.get("x-midgard-internal-upload")?.startsWith("Bearer ")) return new Response(null, { status: 403 });
					return Response.json([...admitted].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0).map(([slug, digest]) => ({ slug, digest })));
				}
				if (url.pathname.startsWith("/api/deployments/")) {
					const route = request.headers.get("x-midgard-public-route");
					if (route) admitted.set(route, "a".repeat(64));
					return Response.json({ slug: route, digest: "a".repeat(64), modules: 342, path: `/run/${route}/` }, { status: 201 });
				}
				return new Response(url.pathname === "/" ? "<h1>Workers</h1>" : "Hello!", { status: 200 });
			} };
		},
	};
	const sql = {
		exec(query: string, ...values: unknown[]) {
			const statement = db.query(query);
			const bindings = values.map((value) => value instanceof ArrayBuffer ? new Uint8Array(value) : value);
			const readOnly = /^(SELECT|PRAGMA)/i.test(query.trim());
			const result = readOnly ? statement.all(...bindings) : (statement.run(...bindings), []);
			return {
				toArray: () => result,
				one: () => result[0],
				[Symbol.iterator]: function* () { yield* result; },
			};
		},
	};
	const ctx = {
		container,
		storage: { sql, transactionSync: (fn: () => unknown) => db.transaction(fn)() },
		blockConcurrencyWhile: (fn: () => Promise<unknown>) => fn(),
	} as unknown as DurableObjectState;
	return { ctx, container, requests, admitted, sql, starts: () => starts, destroys: () => destroys, timeouts: () => timeouts };
}

test("landing, dashboard, worker detail and assets are served by the Worker asset binding", async () => {
	state.calls = 0;
	state.assets = [];
	for (const path of ["/", "/workers", "/workers/hello_abcd1234567890ab", "/assets/app.css", "/assets/favicon.svg"]) {
		const response = await worker.fetch(visit(path), env);
		expect(response.status).toBe(200);
		expect(response.headers.get("cache-control")).toBe(path.startsWith("/assets/") ? "public, max-age=31536000, immutable" : "no-store");
	}
	expect(state.assets).toEqual(["/", "/", "/", "/assets/app.css", "/assets/favicon.svg"]);
	expect((await worker.fetch(visit("/api/deployments/ready"), env)).status).toBe(204);
	expect(state.calls).toBe(1);
});

test("worker subdomains mask internal /run routes and public /run paths are rejected", async () => {
	state.calls = 0;
	state.upstream = [];
	const host = "hello_0123456789abcdef".replaceAll("_", "-") + ".midgard.leostera.dev";
	const response = await worker.fetch(new Request(`https://${host}/hello/joe`, {
		headers: { "cf-connecting-ip": "192.0.2.1" },
	}), env);
	expect(response.status).toBe(200);
	expect(state.upstream).toEqual(["https://midgard.leostera.dev/run/hello_0123456789abcdef/hello/joe"]);

	state.calls = 0;
	expect((await worker.fetch(visit("/run/hello_0123456789abcdef/hello/joe"), env)).status).toBe(404);
	expect(state.calls).toBe(0);
});

test("public worker inventory is served by the runtime API", async () => {
	state.calls = 0;
	const response = await worker.fetch(visit("/api/workers"), env);
	expect(response.status).toBe(200);
	expect(state.calls).toBe(1);
});

test("inventory reads restore shipments and repair missing Worker domains", async () => {
	domainRequests.length = 0;
	attachedDomains.clear();
	const { ctx, sql, starts } = runtimeHarness();
	const runtime = new NativeRuntime(ctx, env);
	const bytes = new Uint8Array([1, 2, 3]);
	const checksum = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)), (byte) => byte.toString(16).padStart(2, "0")).join("");
	const slug = "hello_0123456789abcdef";
	sql.exec("INSERT INTO shipments (slug, app, digest, size, checksum, active, domain_attached) VALUES (?, ?, ?, ?, ?, 1, 1)", slug, "hello", "a".repeat(64), bytes.byteLength, checksum);
	sql.exec("INSERT INTO chunks (slug, part, data) VALUES (?, 0, ?)", slug, bytes.buffer);

	const response = await runtime.fetch(new Request("https://midgard.leostera.dev/api/workers"));
	const body = await response.json() as { workers: Array<{ slug: string }> };
	expect(response.status).toBe(200);
	expect(body.workers.map(({ slug }) => slug)).toEqual([slug]);
	expect(starts()).toBe(1);
	expect(domainRequests).toHaveLength(1);
	expect(domainRequests[0]?.body.hostname).toBe("hello-0123456789abcdef.midgard.leostera.dev");
});

test("unrelated writes and unknown paths never reach the backend", async () => {
	state.calls = 0;
	for (const [path, method] of [["/workers", "POST"], ["/workers/new", "GET"], ["/erlang", "GET"], ["/gleam", "GET"], ["/_midgard/operator/execute-probe", "POST"], ["/bad", "GET"]]) {
		expect((await worker.fetch(visit(path, method), env)).status).toBe(404);
	}
	expect(state.calls).toBe(0);
});

test("public uploads and calls are rate limited before entering the DO", async () => {
	state.calls = 0;
	expect((await worker.fetch(new Request("https://midgard.leostera.dev/"), env)).status).toBe(403);
	state.limited = true;
	expect((await worker.fetch(visit("/"), env)).status).toBe(429);
	state.limited = false;
	state.buildsLimited = true;
	expect((await worker.fetch(visit("/api/deployments/hello", "POST"), env)).status).toBe(429);
	state.buildsLimited = false;
	expect(state.calls).toBe(0);
});

test("a DO restart renews the ten-minute idle period for a surviving container", async () => {
	const { ctx, container, timeouts } = runtimeHarness();
	container.running = true;
	new NativeRuntime(ctx, env);
	await Promise.resolve();
	expect(timeouts()).toBe(1);
});

test("a DO restart reuses only the exact admitted digest set in a surviving Container", async () => {
	const { ctx, container, admitted, requests, starts, destroys } = runtimeHarness();
	const runtime = new NativeRuntime(ctx, env);
	await runtime.fetch(new Request("https://midgard.leostera.dev/api/deployments/ready"));
	const upload = await runtime.fetch(new Request("https://midgard.leostera.dev/api/deployments/hello", {
		method: "POST", headers: { "content-type": "application/vnd.midgard.shipment.v1" }, body: new Uint8Array([0, 1]),
	}));
	const { slug } = await upload.json() as { slug: string };
	expect(starts()).toBe(1);

	const surviving = new NativeRuntime(ctx, env);
	expect((await surviving.fetch(new Request("https://midgard.leostera.dev/"))).status).toBe(200);
	expect(starts()).toBe(1);
	expect(destroys()).toBe(0);
	expect(requests.at(-2)?.url).toEndWith("/api/deployments/state");

	// Missing or mismatched Isolates cannot be reported live after a DO eviction.
	admitted.set(slug, "b".repeat(64));
	const stale = new NativeRuntime(ctx, env);
	expect((await stale.fetch(new Request("https://midgard.leostera.dev/"))).status).toBe(200);
	expect(destroys()).toBe(1);
	expect(starts()).toBe(2);
	expect(admitted.get(slug)).toBe("a".repeat(64));
	container.running = false;
});

test("anonymous uploads receive immutable routes and recover exact stored bytes", async () => {
	domainRequests.length = 0;
	attachedDomains.clear();
	const { ctx, container, requests, starts, destroys } = runtimeHarness();
	const runtime = new NativeRuntime(ctx, env);
	expect((await runtime.fetch(new Request("https://midgard.leostera.dev/api/deployments/ready"))).status).toBe(204);
	const body = new Uint8Array([0, 1, 2, 255]);
	const request = new Request("https://midgard.leostera.dev/api/deployments/hello", {
		method: "POST", headers: { "content-type": "application/vnd.midgard.shipment.v1" }, body,
	});
	const response = await runtime.fetch(request);
	expect(response.status).toBe(201);
	const result = await response.json() as { slug: string };
	expect(result.slug).toMatch(/^hello_[0-9a-f]{16}$/);
	expect(domainRequests[0]?.url).toBe("https://api.cloudflare.com/client/v4/accounts/test-account/workers/domains");
	expect(domainRequests[0]?.body).toMatchObject({
		hostname: `${result.slug.replaceAll("_", "-")}.midgard.leostera.dev`,
		service: "midgard-leostera-dev",
		zone_name: "leostera.dev",
		enabled: true,
		previews_enabled: false,
	});
	const inventory = await runtime.fetch(new Request("https://midgard.leostera.dev/api/workers"));
	const listed = await inventory.json() as { workers: Array<{ slug: string; name: string; url: string; digest: string; size: number }> };
	expect(listed.workers).toEqual([{
		slug: result.slug,
		name: "hello",
		url: `https://${result.slug.replaceAll("_", "-")}.midgard.leostera.dev/`,
		digest: "a".repeat(64),
		size: body.byteLength,
	}]);
	const detail = await runtime.fetch(new Request(`https://midgard.leostera.dev/api/workers/${result.slug}`));
	expect(await detail.json()).toEqual(listed.workers[0]);
	expect((await runtime.fetch(new Request("https://midgard.leostera.dev/api/workers/hello_0000000000000000"))).status).toBe(404);
	expect(requests[1]?.headers.get("x-midgard-internal-upload")?.startsWith("Bearer ")).toBe(true);
	expect(requests[1]?.headers.get("authorization")).toBeNull();
	expect(new Uint8Array(await requests[1]!.arrayBuffer())).toEqual(body);

	const updated = await runtime.fetch(new Request("https://midgard.leostera.dev/api/deployments/hello", {
		method: "POST", headers: { "content-type": "application/vnd.midgard.shipment.v1" }, body: new Uint8Array([3, 4]),
	}));
	expect(updated.status).toBe(201);
	const newRoute = (await updated.json() as { slug: string }).slug;
	expect(newRoute).not.toBe(result.slug);
	expect(starts()).toBe(1);

	container.running = false;
	const afterRestart = new NativeRuntime(ctx, env);
	const call = await afterRestart.fetch(new Request(`https://midgard.leostera.dev/run/${result.slug}/hello`, {
		headers: { authorization: "attacker", "x-midgard-internal-upload": "Bearer fake", cookie: "a=b" },
	}));
	expect(await call.text()).toBe("Hello!");
	expect(starts()).toBe(2);
	expect(destroys()).toBe(0);
	expect(new Uint8Array(await requests[4]!.arrayBuffer())).toEqual(body);
	expect(new Uint8Array(await requests[5]!.arrayBuffer())).toEqual(new Uint8Array([3, 4]));
	expect(requests[6]?.headers.get("authorization")).toBeNull();
	expect(requests[6]?.headers.get("cookie")).toBeNull();
	expect(requests[6]?.headers.get("x-midgard-internal-upload")).toBeNull();
});
