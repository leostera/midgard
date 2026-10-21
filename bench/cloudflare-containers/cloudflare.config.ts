import { defineConfig, defineContainer, exports } from "cf/config";
import * as entrypoint from "./src/index.ts" with { type: "cf-worker" };

// The same Gleam worker modules as the Midgard demo, served by
// bench/container/midgard_http.erl. image/ is prepared by measure.sh.
const bench = defineContainer({
	name: "midgard-container-bench",
	image: { dockerfile: "./image/Dockerfile" },
	instanceType: "standard-1",
	ssh: { enabled: false },
});

export default defineConfig({
	containers: [bench],
	worker: {
		name: "midgard-container-bench",
		compatibilityDate: "2026-09-25",
		workersDev: true,
		entrypoint,
		exports: { Bench: exports.durableObject({ storage: "sqlite", container: bench }) },
	},
});
