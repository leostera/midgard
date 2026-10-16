import { DurableObject, exports as self } from "cloudflare:workers";

// The existing native host and Docker compiler are trusted-local only. Never
// forward public traffic to them. This fixed, token-protected staging probe
// checks the pinned image without admitting or executing uploaded code.
const probePath = "/_midgard/operator/native-probe";

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
	async fetch(): Promise<Response> {
		const container = this.ctx.container;
		if (!container) throw new Error("Native container binding is unavailable");
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

export default {
	async fetch(request: Request, env: Env) {
		if (new URL(request.url).pathname !== probePath || request.method !== "POST") {
			return holdingResponse();
		}
		if (!(await authorized(request, env.STAGING_PROBE_TOKEN))) {
			return new Response("Not found\n", { status: 404, headers: { "cache-control": "no-store" } });
		}

		try {
			const result = await self.NativeRuntime.getByName("operator-staging").fetch("http://runtime.internal/probe");
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
