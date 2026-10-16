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
				"registry.cloudflare.com/0f436d2aabf1f872be90b8dd9d5715e6/midgard-http@sha256:0c487b6839faebad78cb9c15c31280a038fdfa2801484d1d69cb88db0ecddaf5",
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
		env: {
			HTTP_RATE: bindings.rateLimit({ namespace: "1003", simple: { limit: 120, period: 60 } }),
		},
		exports: {
			NativeRuntime: exports.durableObject({ storage: "sqlite", container: platform }),
			CompilerJob: exports.durableObject({ state: "deleted" }),
		},
	},
});
