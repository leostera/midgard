import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as pause } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright-core";

const root = fileURLToPath(new URL("../../../", import.meta.url));
const chrome = process.env.CHROME_PATH;
if (!chrome || !existsSync(chrome)) {
  throw new Error("Set CHROME_PATH to a Chrome/Chromium executable for this optional browser test.");
}

const port = await freePort();
const origin = `http://127.0.0.1:${port}`;
const workspace = mkdtempSync(join(tmpdir(), "midgard-browser-"));
const project = join(workspace, "demo_worker");
const review = join(root, ".impeccable/review");
mkdirSync(review, { recursive: true });
const server = spawn("mix", ["run", "--no-halt"], {
  cwd: root,
  env: { ...process.env, MIDGARD_PORT: String(port), MIDGARD_WORKSPACE: workspace, MIX_ENV: "dev" },
  detached: process.platform !== "win32",
  stdio: ["ignore", "pipe", "pipe"]
});
let log = "";
for (const stream of [server.stdout, server.stderr]) {
  stream.on("data", (data) => { log = (log + data.toString()).slice(-16_000); });
}

let browser;
try {
  await waitForServer();
  browser = await chromium.launch({ executablePath: chrome, headless: true });
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));

  await page.goto(origin, { waitUntil: "networkidle" });
  const commit = execFileSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" }).trim();
  assert.equal(await page.getByRole("link", { name: `View Midgard commit ${commit} on GitHub` }).getAttribute("href"), `https://github.com/leostera/midgard/commit/${commit}`);
  await page.screenshot({ path: join(review, "platform-empty-desktop.png"), fullPage: true });
  await page.getByRole("link", { name: "Create worker" }).first().click();
  await page.getByRole("heading", { name: "Install Midgard" }).waitFor();
  await page.getByRole("heading", { name: "Create your project" }).waitFor();
  await page.getByRole("heading", { name: "Build and deploy" }).waitFor();
  assert.match(await page.locator(".deploy-steps").textContent(), /mix midgard\.deploy/);
  await page.screenshot({ path: join(review, "platform-create-desktop.png"), fullPage: true });

  execFileSync("mix", ["midgard.new", "demo_worker", "--path", project, "--midgard-root", root], { cwd: root });
  execFileSync("mix", ["deps.get"], { cwd: project });
  const result = execFileSync("mix", ["midgard.deploy", "--endpoint", origin], { cwd: project, encoding: "utf8" });
  assert.match(result, /Deployed demo_worker/);
  assert.equal(await (await fetch(`${origin}/run/demo_worker/hello`)).text(), "hello, world!");

  await page.goto(origin, { waitUntil: "networkidle" });
  assert.match(await page.locator(".worker-table").textContent(), /demo_worker[\s\S]*Deployed/);
  assert.equal(await page.locator(".worker-table th").count(), 6);
  assert.equal(await page.locator(".worker-table tbody td:nth-child(2)").textContent(), "Elixir");
  await page.getByRole("link", { name: "Language" }).click();
  assert.match(page.url(), /sort=language/);
  assert.equal(await page.locator(".worker-table .details-link").getAttribute("href"), "/workers/demo_worker");
  await page.screenshot({ path: join(review, "desktop.png"), fullPage: true });
  await page.getByRole("searchbox", { name: "Search workers" }).fill("not_here");
  await page.getByRole("button", { name: "Search" }).click();
  await page.getByText("No matching workers").waitFor();
  await page.getByRole("link", { name: "Clear filters" }).click();
  await page.getByRole("link", { name: "Open details for demo_worker" }).click();
  await page.getByText("Managed by a local Midgard project.").waitFor();
  assert.match(await page.locator(".live-panel").textContent(), /other projects may use different paths/);
  assert.match(await page.locator(".live-panel").textContent(), /Elixir/);
  await page.screenshot({ path: join(review, "platform-deployed-desktop.png"), fullPage: true });

  const mobile = await browser.newPage({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  mobile.on("pageerror", (error) => errors.push(error.message));
  await mobile.goto(`${origin}/workers/new`, { waitUntil: "networkidle" });
  assert.equal(await mobile.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
  await mobile.screenshot({ path: join(review, "platform-create-mobile.png"), fullPage: true });
  await mobile.goto(origin, { waitUntil: "networkidle" });
  assert.equal(await mobile.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
  assert.equal(await mobile.getByRole("link", { name: "Language" }).isVisible(), true);
  assert.equal(await mobile.locator(".worker-table .details-link").isVisible(), true);
  await mobile.screenshot({ path: join(tmpdir(), "midgard-ui-mobile-inventory.png"), fullPage: true });
  await mobile.goto(`${origin}/workers/demo_worker`, { waitUntil: "networkidle" });
  assert.equal(await mobile.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
  await mobile.screenshot({ path: join(review, "platform-deployed-mobile.png"), fullPage: true });

  const beam = join(project, "demo_worker.midgard", "modules", "Elixir.DemoWorker.beam");
  const original = readFileSync(beam);
  writeFileSync(beam, Buffer.concat([Buffer.from([0]), original.subarray(1)]));
  assert.throws(() => execFileSync("mix", ["midgard.deploy", "--artifact", join(project, "demo_worker.midgard"), "--endpoint", origin], { cwd: project, stdio: "pipe" }), /checksum mismatch/);
  assert.equal(await (await fetch(`${origin}/run/demo_worker/hello`)).text(), "hello, world!");
  assert.deepEqual(errors, []);
  console.log("Browser guide and responsive deployed inventory; CLI upload, Isolate call and rejected update passed.");
} finally {
  if (browser) await browser.close();
  if (server.exitCode === null) {
    if (process.platform === "win32") server.kill("SIGTERM");
    else process.kill(-server.pid, "SIGTERM");
  }
  rmSync(workspace, { recursive: true, force: true });
}

async function freePort() {
  const listener = createServer();
  await new Promise((resolve, reject) => listener.listen(0, "127.0.0.1", (error) => error ? reject(error) : resolve()));
  const { port } = listener.address();
  await new Promise((resolve) => listener.close(resolve));
  return port;
}

async function waitForServer() {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (server.exitCode !== null) throw new Error(`Local server exited early:\n${log}`);
    try {
      const response = await fetch(origin);
      if (response.ok) return;
    } catch { /* Still starting. */ }
    await pause(150);
  }
  throw new Error(`Local server did not become ready:\n${log}`);
}
