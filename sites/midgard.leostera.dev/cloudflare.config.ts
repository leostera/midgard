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
				"registry.cloudflare.com/0f436d2aabf1f872be90b8dd9d5715e6/midgard-http@sha256:51b17ce4c9b7cc03cfd82dc5304fdf72ffa73e8f693d86fd30c7a166bdd1e087",
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
		domains: ["midgard.leostera.dev"],
		entrypoint,
		observability: { enabled: true, logs: { enabled: true }, traces: { enabled: true, headSamplingRate: 0.1 } },
		env: {
			HTTP_RATE: bindings.rateLimit({ namespace: "1003", simple: { limit: 120, period: 60 } }),
			DEPLOY_RATE: bindings.rateLimit({ namespace: "1004", simple: { limit: 2, period: 60 } }),
		},
		exports: {
			NativeRuntime: exports.durableObject({ storage: "sqlite", container: platform }),
		},
	},
});
