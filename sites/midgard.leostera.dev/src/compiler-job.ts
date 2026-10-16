import { DurableObject } from "cloudflare:workers";

// Operator smoke test only. No public request can select source or invoke this
// class yet; production jobs will use one fresh, destroyed VM per revision.
const smokeSource = `defmodule Probe do
  use Midgard.Worker

  def handle_request(%Midgard.Request{path: "/hello/" <> name}) do
    {200, "Hello, #{name}!\\n"}
  end

  def handle_request(_), do: {404, "Not found\\n"}
end
`;

export class CompilerJob extends DurableObject<Env> {
	async fetch(request: Request): Promise<Response> {
		const container = this.ctx.container;
		if (!container) throw new Error("Compiler container binding is unavailable");
		if (container.running) throw new Error("Compiler job must start from a fresh VM");
		container.start({
			image: container.images.compiler,
			instance: "standard-1",
			enableInternet: false,
		});
		try {
			const upload = await container.exec(["/usr/bin/tee", "/workspace/worker.ex"], { stdin: "pipe", stdout: "ignore" });
			const writer = upload.stdin?.getWriter();
			if (!writer) throw new Error("Compiler upload stream unavailable");
			await writer.write(new TextEncoder().encode(smokeSource));
			await writer.close();
			if ((await upload.output()).exitCode !== 0) throw new Error("Compiler source upload failed");

			const build = await container.exec([
				"/usr/bin/timeout", "-k", "5s", "60s", "/usr/local/bin/elixir",
				"/workspace/compile.exs", "probe", "Elixir.Probe", container.images.compiler,
			]);
			const result = await build.output();
			if (result.exitCode !== 0) throw new Error(`Compiler smoke test exited ${result.exitCode}`);

			const manifestProcess = await container.exec(["/usr/bin/cat", "/output/manifest.json"]);
			const manifestOutput = await manifestProcess.output();
			if (manifestOutput.exitCode !== 0 || manifestOutput.stdout.byteLength > 1_000_000) {
				throw new Error("Compiler manifest is missing or too large");
			}
			const manifest: unknown = JSON.parse(new TextDecoder().decode(manifestOutput.stdout));
			if (!isProbeManifest(manifest)) throw new Error("Compiler output is not a Probe shipment");
			if (new URL(request.url).pathname !== "/package") {
				return Response.json({ compiled: true, modules: manifest.modules.length });
			}
			const archive = await container.exec([
				"/usr/bin/tar", "-cf", "-", "-C", "/output", "manifest.json", "modules",
			]);
			const packaged = await archive.output();
			if (packaged.exitCode !== 0 || packaged.stdout.byteLength > 40_000_000) {
				throw new Error("Compiler archive failed or exceeds its size limit");
			}
			return new Response(packaged.stdout, { headers: { "content-type": "application/x-tar" } });
		} finally {
			await container.destroy();
		}
	}
}

function isProbeManifest(value: unknown): value is { modules: unknown[] } {
	if (!value || typeof value !== "object") return false;
	const record = value as Record<string, unknown>;
	return record.format === "midgard.beam" && record.application === "probe" &&
		Array.isArray(record.modules) && record.modules.length > 0 && record.modules.length <= 512;
}
