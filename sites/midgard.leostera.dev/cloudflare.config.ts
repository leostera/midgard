import { bindings, defineConfig } from "cf/config";
import * as entrypoint from "./src/index.ts" with { type: "cf-worker" };

export default defineConfig({
	worker: {
		name: "midgard-leostera-dev",
		compatibilityDate: "2026-09-25",
		entrypoint,
		env: {
			WORLD: bindings.text("World"),
		},
	},
});
