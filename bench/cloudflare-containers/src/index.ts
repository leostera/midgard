import { DurableObject, exports as self } from "cloudflare:workers";

// One container behind one Durable Object, the documented Cloudflare
// Containers shape. GET /__stop destroys it so the next request cold-starts.
export class Bench extends DurableObject {
	async fetch(request: Request): Promise<Response> {
		const container = this.ctx.container!;
		const url = new URL(request.url);
		if (url.pathname === "/__stop") {
			if (container.running) await container.destroy();
			return new Response("stopped\n");
		}
		const started = Date.now();
		const wasRunning = container.running;
		for (;;) {
			try {
				// Retry start until scheduled: it can fail while capacity frees up.
				if (!container.running) container.start({ enableInternet: false });
				// A port taken before start() stays bound to the previous instance.
				const port = container.getTcpPort(8080);
				const response = await port.fetch(`http://container${url.pathname}${url.search}`, request);
				const headers = new Headers(response.headers);
				headers.set("x-container-was-running", String(wasRunning));
				headers.set("x-container-wait-ms", String(Date.now() - started));
				return new Response(response.body, { status: response.status, headers });
			} catch (error) {
				if (Date.now() - started > 120_000) return new Response(`container did not start: ${error}\n`, { status: 503 });
				await new Promise((resolve) => setTimeout(resolve, 50));
			}
		}
	}
}

export default {
	fetch(request: Request): Promise<Response> {
		return self.Bench.getByName("bench").fetch(request);
	},
};
