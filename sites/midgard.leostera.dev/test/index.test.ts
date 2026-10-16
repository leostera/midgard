import { expect, mock, test } from "bun:test";

const state = { calls: 0, limited: false };
mock.module("cloudflare:workers", () => ({
	DurableObject: class {
		ctx: unknown;
		constructor(ctx: unknown) { this.ctx = ctx; }
	},
	exports: {
		NativeRuntime: {
			getByName(name: string) {
				expect(name).toBe("platform");
				return {
					fetch: async () => {
						state.calls++;
						return new Response("<h1>Workers</h1>", { headers: { "content-type": "text/html" } });
					},
				};
			},
		},
	},
}));
const { default: worker, NativeRuntime } = await import("../src/index.ts");
const env = {
	HTTP_RATE: { limit: async () => ({ success: !state.limited }) },
} as unknown as Env;
const visit = (path: string, method = "GET") => new Request(`https://midgard.leostera.dev${path}`, {
	method,
	headers: { "cf-connecting-ip": "192.0.2.1" },
});

test("GET inventory and assets pass through to the persistent Elixir service", async () => {
	state.calls = 0;
	for (const path of ["/", "/assets/app.css", "/assets/favicon.svg"]) {
		const response = await worker.fetch(visit(path), env);
		expect(response.status).toBe(200);
		expect(response.headers.get("cache-control")).toBe("no-store");
	}
	expect(state.calls).toBe(3);
});

test("public writes and unknown paths never reach the backend", async () => {
	state.calls = 0;
	for (const [path, method] of [["/workers", "POST"], ["/workers/new", "GET"],
		["/_midgard/operator/execute-probe", "POST"], ["/run/test/hello", "GET"]]) {
		expect((await worker.fetch(visit(path, method), env)).status).toBe(503);
	}
	expect(state.calls).toBe(0);
});

test("missing edge client identity and rate limits fail closed", async () => {
	state.calls = 0;
	expect((await worker.fetch(new Request("https://midgard.leostera.dev/"), env)).status).toBe(403);
	state.limited = true;
	expect((await worker.fetch(visit("/"), env)).status).toBe(429);
	state.limited = false;
	expect(state.calls).toBe(0);
});

test("DO forwards HTTP to the Elixir port without exec or public headers", async () => {
	let startup: unknown;
	let target: Request | undefined;
	const container = {
		running: false,
		images: { server: "midgard-runtime@sha256:example" },
		start(options: unknown) { startup = options; this.running = true; },
		async setInactivityTimeout(value: number) { expect(value).toBe(120_000); },
		getTcpPort(port: number) {
			expect(port).toBe(4000);
			return { fetch: async (request: Request) => {
				target = request;
				return new Response("Elixir response");
			} };
		},
	};
	const runtime = new NativeRuntime({ container } as unknown as DurableObjectState, env);
	const request = new Request("https://midgard.leostera.dev/?q=hello", {
		headers: { authorization: "Bearer browser-input", cookie: "untrusted=1" },
	});
	const response = await runtime.fetch(request);
	expect(await response.text()).toBe("Elixir response");
	expect(startup).toEqual({
		image: "midgard-runtime@sha256:example", instance: "standard-1",
		enableInternet: false, env: { MIDGARD_CONTAINER_HTTP: "1" },
	});
	expect(target?.url).toBe("http://127.0.0.1:4000/?q=hello");
	expect(target?.headers.get("authorization")).toBeNull();
	expect(target?.headers.get("cookie")).toBeNull();
});
