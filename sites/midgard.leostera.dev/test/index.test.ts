import { expect, mock, test } from "bun:test";
import { timingSafeEqual } from "node:crypto";

// Bun doesn't implement the Cloudflare runtime; the deployed Durable Object
// is also exercised by the operator probe on the actual Container service.
const nativeRuntime = {
	getByName(name: string) {
		expect(name).toBe("operator-staging");
		return { fetch: async () => Response.json({ running: true, httpStatus: "200", exitCode: 0 }) };
	},
};
mock.module("cloudflare:workers", () => ({
	DurableObject: class {
		ctx: unknown;
		constructor(ctx: unknown) { this.ctx = ctx; }
	},
	exports: {
		NativeRuntime: nativeRuntime,
		CompilerJob: {
			newUniqueId: () => "unique-compiler-job",
			get: (id: string) => {
				expect(id).toBe("unique-compiler-job");
				return { fetch: async () => Response.json({ compiled: true, modules: 12 }) };
			},
		},
	},
}));
// Bun's Web Crypto lacks the Cloudflare-only timingSafeEqual extension.
Object.defineProperty(crypto.subtle, "timingSafeEqual", {
	value: (a: ArrayBuffer, b: ArrayBuffer) => timingSafeEqual(Buffer.from(a), Buffer.from(b)),
});
const { default: worker, NativeRuntime } = await import("../src/index.ts");

const probeUrl = "https://midgard.leostera.dev/_midgard/operator/native-probe";
const env = { STAGING_PROBE_TOKEN: "test-secret" } as Env;

test("public hostname serves a real empty inventory without exposing writes", async () => {
	const response = await worker.fetch(new Request("https://midgard.leostera.dev/"), env);
	const body = await response.text();

	expect(response.status).toBe(200);
	expect(body).toContain("Compute");
	expect(body).toContain("No public workers yet");
	expect(body).toContain("Create worker · Not yet available");
	expect(body).not.toContain("/workers/new");
	expect(response.headers.get("cache-control")).toBe("no-store");
	expect(response.headers.get("x-robots-tag")).toBe("noindex");
});

test("dashboard assets load without granting upload access", async () => {
	for (const [path, contentType] of [
		["/assets/app.css", "text/css; charset=utf-8"],
		["/assets/favicon.svg", "image/svg+xml"],
	]) {
		const response = await worker.fetch(new Request(`https://midgard.leostera.dev${path}`), env);
		expect(response.status).toBe(200);
		expect(response.headers.get("content-type")).toBe(contentType);
	}
	expect((await worker.fetch(new Request("https://midgard.leostera.dev/workers", { method: "POST" }), env)).status).toBe(503);
});

test("unknown paths and GET probes never boot a container", async () => {
	for (const request of [
		new Request("https://midgard.leostera.dev/anything", { method: "POST" }),
		new Request(probeUrl),
	]) {
		expect((await worker.fetch(request, env)).status).toBe(503);
	}
});

test("missing or incorrect tokens cannot reach the container binding", async () => {
	const original = nativeRuntime.getByName;
	nativeRuntime.getByName = () => { throw new Error("unauthorized request reached container binding"); };
	try {
		for (const authorization of [undefined, "Bearer wrong", "test-secret"]) {
			const request = new Request(probeUrl, {
				method: "POST",
				headers: authorization ? { authorization } : {},
			});
			const response = await worker.fetch(request, env);
			expect(response.status).toBe(404);
		}
	} finally {
		nativeRuntime.getByName = original;
	}
});

test("native probe starts the pinned image offline and checks loopback HTTP", async () => {
	let startup: unknown;
	let timeout: unknown;
	const container = {
		running: false,
		images: { native: "pinned-image@sha256:example" },
		start(options: unknown) { startup = options; this.running = true; },
		async setInactivityTimeout(value: unknown) { timeout = value; },
		async exec(command: string[]) {
			expect(command.at(-1)).toBe("http://127.0.0.1:4000/");
			return { output: async () => ({
				stdout: new TextEncoder().encode("200").buffer,
				exitCode: 0,
			}) };
		},
	};
	const runtime = new NativeRuntime({ container } as unknown as DurableObjectState, env);
	const response = await runtime.fetch(new Request("http://runtime.internal/probe"));
	expect(startup).toEqual({
		image: "pinned-image@sha256:example", instance: "standard-1", enableInternet: false,
	});
	expect(timeout).toBe(120_000);
	expect(response.status).toBe(200);
	expect(await response.json()).toEqual({ running: true, httpStatus: "200", exitCode: 0 });
});

test("compiler probe requires the same operator token and a fresh job", async () => {
	const url = "https://midgard.leostera.dev/_midgard/operator/compiler-probe";
	expect((await worker.fetch(new Request(url, { method: "POST" }), env)).status).toBe(404);
	const response = await worker.fetch(new Request(url, {
		method: "POST",
		headers: { authorization: "Bearer test-secret" },
	}), env);
	expect(response.status).toBe(200);
	expect(await response.json()).toEqual({ compiled: true, modules: 12 });
});

test("operator-only probe returns a bounded status without forwarding public traffic", async () => {
	const response = await worker.fetch(new Request(probeUrl, {
		method: "POST",
		headers: { authorization: "Bearer test-secret" },
	}), env);
	expect(response.status).toBe(200);
	expect(await response.json()).toEqual({ running: true, httpStatus: "200", exitCode: 0 });
	expect(response.headers.get("cache-control")).toBe("no-store");
});
