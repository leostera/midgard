import { bindings, defineConfig, defineContainer, exports } from "cf/config";
import * as entrypoint from "./src/index.ts" with { type: "cf-worker" };

// The edge Worker is the only ingress. One DO owns one persistent Elixir HTTP
// service; no public request runs a process with container.exec().
const platform = defineContainer({
	name: "midgard-native-runtime",
	schedulingPolicy: "durable-object",
	images: {
		server: {
			reference:
				"registry.cloudflare.com/0f436d2aabf1f872be90b8dd9d5715e6/midgard-http@sha256:2d62d0989e27248b7d19d751cc0ae6d067332886f41a55561d23752837f236e5",
		},
	},
	ssh: { enabled: false },
	observability: { enabled: true, logs: { enabled: true } },
});

export default defineConfig({
	containers: [platform],
	worker: {
		name: "midgard-leostera-dev",
		compatibilityDate: "2026-09-25",
		assets: { notFoundHandling: "single-page-application", runWorkerFirst: true },
		domains: ["midgard.leostera.dev"],
		entrypoint,
		observability: { enabled: true, logs: { enabled: true }, traces: { enabled: true, headSamplingRate: 0.1 } },
		env: {
			ASSETS: bindings.assets(),
			CLOUDFLARE_ACCOUNT_ID: bindings.text("0f436d2aabf1f872be90b8dd9d5715e6"),
			CF_DNS_API_TOKEN: bindings.secret(),
			CLOUDFLARE_WORKER_NAME: bindings.text("midgard-leostera-dev"),
			HTTP_RATE: bindings.rateLimit({ namespace: "1003", simple: { limit: 120, period: 60 } }),
			DEPLOY_RATE: bindings.rateLimit({ namespace: "1004", simple: { limit: 2, period: 60 } }),
		},
		exports: {
			NativeRuntime: exports.durableObject({ storage: "sqlite", container: platform }),
		},
	},
});
