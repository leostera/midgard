import { DurableObject, exports as self } from "cloudflare:workers";

const origin = "https://midgard.leostera.dev";
const backend = "http://127.0.0.1:4000";
const publicPaths = new Set(["/", "/assets/app.css", "/assets/favicon.svg"]);

function unavailable(): Response {
	return new Response("Public worker creation is not available yet.\n", {
		status: 503,
		headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store", "x-robots-tag": "noindex" },
	});
}

export class NativeRuntime extends DurableObject<Env> {
	async fetch(request: Request): Promise<Response> {
		const container = this.ctx.container;
		if (!container) throw new Error("Platform container binding is unavailable");
		const starting = !container.running;
		if (starting) {
			container.start({
				image: container.images.server,
				instance: "standard-1",
				enableInternet: false,
				env: { MIDGARD_CONTAINER_HTTP: "1" },
			});
		}
		await container.setInactivityTimeout(120_000);
		const url = new URL(request.url);
		const headers = new Headers(request.headers);
		// The serving Plug is local-host-only. This Host value is set here, never
		// forwarded from a visitor. The TCP port is private to this DO instance.
		headers.set("host", "127.0.0.1:4000");
		headers.delete("authorization");
		headers.delete("cookie");
		const upstream = new Request(`${backend}${url.pathname}${url.search}`, {
			method: request.method,
			headers,
		});
		const port = container.getTcpPort(4000);
		for (let attempt = 0; attempt < 15; attempt++) {
			try {
				return await port.fetch(upstream);
			} catch (error) {
				// Retry only cold-start GETs. Never replay a write after uncertain
				// delivery. A warm container error is a real backend failure.
				if (!starting || attempt === 14) throw error;
				await new Promise((resolve) => setTimeout(resolve, 2_000));
			}
		}
		throw new Error("Platform did not become ready");
	}
}

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		const url = new URL(request.url);
		if (url.origin !== origin || request.method !== "GET" || !publicPaths.has(url.pathname)) {
			return unavailable();
		}
		const clientAddress = request.headers.get("cf-connecting-ip");
		if (!clientAddress) return new Response("Forbidden\n", { status: 403 });
		const { success } = await env.HTTP_RATE.limit({ key: clientAddress });
		if (!success) return new Response("Too many requests\n", { status: 429, headers: { "retry-after": "60" } });
		try {
			const response = await self.NativeRuntime.getByName("platform").fetch(request);
			const headers = new Headers(response.headers);
			headers.set("cache-control", "no-store");
			headers.set("x-content-type-options", "nosniff");
			return new Response(response.body, { status: response.status, headers });
		} catch (error) {
			console.error("Elixir platform unavailable", error);
			return unavailable();
		}
	},
} satisfies ExportedHandler<Env>;
