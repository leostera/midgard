import { DurableObject, exports as self } from "cloudflare:workers";
import { dashboardCss, dashboardFavicon, dashboardHtml } from "./dashboard.ts";
export { CompilerJob } from "./compiler-job.ts";
import { executeShipment } from "./runtime-job.ts";

// The existing native host and Docker compiler are trusted-local only. Never
// forward public traffic to them. This fixed, token-protected staging probe
// checks the pinned image without admitting or executing uploaded code.
const probePath = "/_midgard/operator/native-probe";
const compilerProbePath = "/_midgard/operator/compiler-probe";
const executeProbePath = "/_midgard/operator/execute-probe";

function holdingResponse() {
	return new Response("Midgard is preparing for public launch. No workers are available yet.\n", {
		status: 503,
		headers: {
			"content-type": "text/plain; charset=utf-8",
			"cache-control": "no-store",
			"x-content-type-options": "nosniff",
			"x-robots-tag": "noindex",
		},
	});
}

async function authorized(request: Request, token: string | undefined): Promise<boolean> {
	if (!token) return false;
	const supplied = request.headers.get("authorization") ?? "";
	const encoder = new TextEncoder();
	const [actual, expected] = await Promise.all([
		crypto.subtle.digest("SHA-256", encoder.encode(supplied)),
		crypto.subtle.digest("SHA-256", encoder.encode(`Bearer ${token}`)),
	]);
	return crypto.subtle.timingSafeEqual(actual, expected);
}

export class NativeRuntime extends DurableObject<Env> {
	async fetch(request: Request): Promise<Response> {
		const container = this.ctx.container;
		if (!container) throw new Error("Native container binding is unavailable");
		if (new URL(request.url).pathname === "/execute") return executeShipment(container, request);
		if (!container.running) {
			container.start({
				image: container.images.native,
				instance: "standard-1",
				enableInternet: false,
			});
		}
		await container.setInactivityTimeout(120_000);
		// exec waits for the VM, not for Bandit to finish booting. Retry only
		// connection failures; an HTTP error is a real service response.
		// The service is loopback-only; neither its body nor a TCP port is exposed.
		for (let attempt = 0; attempt < 15; attempt++) {
			const process = await container.exec([
				"/usr/bin/curl", "--silent", "--output", "/dev/null", "--max-time", "5",
				"--write-out", "%{http_code}", "http://127.0.0.1:4000/",
			]);
			const output = await process.output();
			const httpStatus = new TextDecoder().decode(output.stdout);
			if (output.exitCode === 7 && attempt < 14) {
				await new Promise((resolve) => setTimeout(resolve, 2_000));
				continue;
			}
			return Response.json(
				{ running: container.running, httpStatus, exitCode: output.exitCode },
				{ status: output.exitCode === 0 && httpStatus === "200" ? 200 : 502 },
			);
		}
		throw new Error("Native probe exhausted its retry budget");
	}
}

async function executeProbe(env: Env): Promise<Response> {
	const compiled = await self.CompilerJob.get(self.CompilerJob.newUniqueId()).fetch("http://compiler.internal/package");
	if (!compiled.ok) throw new Error("Offline compiler did not produce a package");
	const archive = await compiled.arrayBuffer();
	if (archive.byteLength < 1 || archive.byteLength > 40_000_000) throw new Error("Compiler package size exceeded");
	const checksum = [...new Uint8Array(await crypto.subtle.digest("SHA-256", archive))]
		.map((byte) => byte.toString(16).padStart(2, "0")).join("");
	const key = `staging/${crypto.randomUUID()}.tar`;
	await env.SHIPMENTS.put(key, archive, {
		customMetadata: { sha256: checksum },
		httpMetadata: { contentType: "application/x-tar" },
	});
	const stored = await env.SHIPMENTS.get(key);
	if (!stored || stored.size !== archive.byteLength || stored.customMetadata?.sha256 !== checksum) {
		throw new Error("Exact shipment could not be recovered from durable storage");
	}
	const recovered = await stored.arrayBuffer();
	const recoveredHash = [...new Uint8Array(await crypto.subtle.digest("SHA-256", recovered))]
		.map((byte) => byte.toString(16).padStart(2, "0")).join("");
	if (recoveredHash !== checksum) throw new Error("Recovered shipment bytes changed");
	const result = await self.NativeRuntime.getByName("operator-execution-probe").fetch(
		"http://runtime.internal/execute", {
			method: "POST",
			headers: { "content-length": String(recovered.byteLength) },
			body: recovered,
		},
	);
	return new Response(result.body, {
		status: result.status,
		headers: { "content-type": "application/json", "cache-control": "no-store" },
	});
}

export default {
	async fetch(request: Request, env: Env) {
		const path = new URL(request.url).pathname;
		if (request.method === "GET") {
			if (path === "/") {
				return new Response(dashboardHtml, {
					headers: {
						"content-type": "text/html; charset=utf-8",
						"cache-control": "no-store",
						"x-content-type-options": "nosniff",
						"x-robots-tag": "noindex",
						"content-security-policy": "default-src 'none'; style-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
					},
				});
			}
			if (path === "/assets/app.css" || path === "/assets/favicon.svg") {
				return new Response(path.endsWith(".css") ? dashboardCss : dashboardFavicon, {
					headers: {
						"content-type": path.endsWith(".css") ? "text/css; charset=utf-8" : "image/svg+xml",
						"cache-control": "public, max-age=3600",
						"x-content-type-options": "nosniff",
					},
				});
			}
		}
		if ((path !== probePath && path !== compilerProbePath && path !== executeProbePath) || request.method !== "POST") {
			return holdingResponse();
		}
		if (!(await authorized(request, env.STAGING_PROBE_TOKEN))) {
			return new Response("Not found\n", { status: 404, headers: { "cache-control": "no-store" } });
		}

		try {
			if (path === executeProbePath) return await executeProbe(env);
			const result = path === compilerProbePath
				? await self.CompilerJob.get(self.CompilerJob.newUniqueId()).fetch("http://compiler.internal/probe")
				: await self.NativeRuntime.getByName("operator-staging").fetch("http://runtime.internal/probe");
			return new Response(result.body, {
				status: result.status,
				headers: { "content-type": "application/json", "cache-control": "no-store" },
			});
		} catch (error) {
			console.error("Native staging probe failed", error);
			return new Response("Native staging probe failed\n", {
				status: 502,
				headers: { "cache-control": "no-store" },
			});
		}
	},
} satisfies ExportedHandler<Env>;
