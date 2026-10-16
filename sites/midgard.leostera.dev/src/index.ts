// Do not expose the trusted-local editor or a native Isolate host through this
// public Worker until isolated compilation, durable admission and abuse controls
// are in place. A deployed domain is not a deployed Midgard runtime.
export default {
	fetch() {
		return new Response("Midgard is preparing for public launch. No workers are available yet.\n", {
			status: 503,
			headers: {
				"content-type": "text/plain; charset=utf-8",
				"cache-control": "no-store",
				"x-content-type-options": "nosniff",
				"x-robots-tag": "noindex",
			},
		});
	},
} satisfies ExportedHandler;
