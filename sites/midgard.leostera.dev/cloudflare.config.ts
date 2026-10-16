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

// One fresh offline VM per build. The image contains no Cloudflare credentials;
// only shipment bytes may leave it, and it is destroyed after every job.
const compilerJob = defineContainer({
	name: "midgard-compiler-jobs",
	schedulingPolicy: "durable-object",
	images: {
		compiler: {
			reference:
				"registry.cloudflare.com/0f436d2aabf1f872be90b8dd9d5715e6/midgard-compiler@sha256:a34996d9338f9cd37f32496f265ff94da3a52ca517bb0a6f80f5eb191706e677",
		},
	},
	ssh: { enabled: false },
	observability: { enabled: true, logs: { enabled: true } },
});

export default defineConfig({
	containers: [nativeRuntime, compilerJob],
	worker: {
		name: "midgard-leostera-dev",
		compatibilityDate: "2026-09-25",
		domains: ["midgard.leostera.dev"],
		entrypoint,
		env: {
			STAGING_PROBE_TOKEN: bindings.secret(),
			SHIPMENTS: bindings.r2({ name: "midgard-public-shipments" }),
			WORKER_SOURCES: bindings.artifacts({ namespace: "midgard-workers" }),
			CREATE_RATE: bindings.rateLimit({ namespace: "1001", simple: { limit: 2, period: 60 } }),
			CALL_RATE: bindings.rateLimit({ namespace: "1002", simple: { limit: 60, period: 60 } }),
		},
		exports: {
			NativeRuntime: exports.durableObject({ storage: "sqlite", container: nativeRuntime }),
			CompilerJob: exports.durableObject({ storage: "sqlite", container: compilerJob }),
		},
	},
});
