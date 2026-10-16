import { bindings, defineConfig, defineContainer, exports } from "cf/config";
import * as entrypoint from "./src/index.ts" with { type: "cf-worker" };

// The pinned image is trusted-local staging infrastructure, not an upload
// compiler or a multi-tenant runtime. Only the operator probe can boot it.
const nativeRuntime = defineContainer({
	name: "midgard-native-runtime",
	schedulingPolicy: "durable-object",
	images: {
		native: {
			reference:
				"registry.cloudflare.com/0f436d2aabf1f872be90b8dd9d5715e6/midgard-runtime@sha256:6f3e271f15ac28dcd3c39bd64703654934ee1d2501f2de1b9515c684201b5504",
		},
	},
	ssh: { enabled: false },
	observability: { enabled: true, logs: { enabled: true } },
});

export default defineConfig({
	containers: [nativeRuntime],
	worker: {
		name: "midgard-leostera-dev",
		compatibilityDate: "2026-09-25",
		domains: ["midgard.leostera.dev"],
		entrypoint,
		env: {
			STAGING_PROBE_TOKEN: bindings.secret(),
		},
		exports: {
			NativeRuntime: exports.durableObject({ storage: "sqlite", container: nativeRuntime }),
		},
	},
});
