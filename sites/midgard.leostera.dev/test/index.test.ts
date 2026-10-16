import { expect, mock, test } from "bun:test";
import { Database } from "bun:sqlite";

const state = { calls: 0, limited: false, buildsLimited: false };
mock.module("cloudflare:workers", () => ({
	DurableObject: class {
		ctx: unknown;
		constructor(ctx: unknown) { this.ctx = ctx; }
	},
	exports: {
		NativeRuntime: {
			getByName(name: string) {
				expect(name).toBe("platform");
				return { fetch: async () => {
					state.calls++;
					return new Response("<h1>Workers</h1>", { headers: { "content-type": "text/html" } });
				} };
			},
		},
	},
}));
const { default: worker, NativeRuntime } = await import("../src/index.ts");
const env = {
	HTTP_RATE: { limit: async () => ({ success: !state.limited }) },
	DEPLOY_RATE: { limit: async () => ({ success: !state.buildsLimited }) },
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
	const container = {
		running: false,
		images: { server: "midgard-runtime@sha256:example" },
		start(options: { env: Record<string, string>; instance: string }) {
			expect(options.instance).toBe("standard-2");
			expect(options.env.MIDGARD_INTERNAL_UPLOAD_KEY.length).toBe(64);
			this.running = true;
			starts++;
		},
		async destroy() { destroys++; this.running = false; },
		async setInactivityTimeout(value: number) { expect(value).toBe(21_600_000); timeouts++; },
		getTcpPort(port: number) {
			expect(port).toBe(4000);
			return { fetch: async (request: Request) => {
				requests.push(request);
				const url = new URL(request.url);
				if (url.pathname.startsWith("/api/deployments/")) {
					const route = request.headers.get("x-midgard-public-route");
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
			const result = query.trim().toUpperCase().startsWith("SELECT") ? statement.all(...bindings) : (statement.run(...bindings), []);
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
	return { ctx, container, requests, starts: () => starts, destroys: () => destroys, timeouts: () => timeouts };
}

test("dashboard, guide and assets pass through the private Elixir service", async () => {
	state.calls = 0;
	for (const path of ["/", "/workers/new", "/workers/hello_abcd1234", "/assets/app.css", "/assets/favicon.svg"]) {
		const response = await worker.fetch(visit(path), env);
		expect(response.status).toBe(200);
		expect(response.headers.get("cache-control")).toBe("no-store");
	}
	expect((await worker.fetch(visit("/api/deployments/ready"), env)).status).toBe(204);
	expect(state.calls).toBe(6);
});

test("unrelated writes and unknown paths never reach the backend", async () => {
	state.calls = 0;
	for (const [path, method] of [["/workers", "POST"], ["/_midgard/operator/execute-probe", "POST"], ["/bad", "GET"]]) {
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

test("a DO restart renews the maximum sleep period for a surviving container", async () => {
	const { ctx, container, timeouts } = runtimeHarness();
	container.running = true;
	new NativeRuntime(ctx, env);
	await Promise.resolve();
	expect(timeouts()).toBe(1);
});

test("anonymous uploads receive immutable routes and recover exact stored bytes", async () => {
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
