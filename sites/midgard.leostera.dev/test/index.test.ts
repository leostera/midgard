import { expect, test } from "bun:test";
import worker from "../src/index.ts";

test("public hostname stays closed until workers can run safely", async () => {
	const response = await worker.fetch();
	const body = await response.text();

	expect(response.status).toBe(503);
	expect(body).toContain("No workers are available yet");
	expect(response.headers.get("cache-control")).toBe("no-store");
	expect(response.headers.get("x-robots-tag")).toBe("noindex");
});
