import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, rmSync } from "node:fs";
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
  page.on("console", (message) => {
    if (message.type() === "error" && !message.text().includes("422")) errors.push(message.text());
  });

  await page.goto(origin, { waitUntil: "networkidle" });
  const commit = execFileSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" }).trim();
  assert.equal(await page.getByRole("link", { name: `View Midgard commit ${commit} on GitHub` }).getAttribute("href"), `https://github.com/leostera/midgard/commit/${commit}`);
  await page.evaluate(() => document.fonts.ready);
  await page.screenshot({ path: join(review, "platform-empty-desktop.png"), fullPage: true });
  await page.getByRole("link", { name: "Create worker" }).first().click();
  await page.getByLabel("Worker name").fill("demo_worker");
  await page.getByRole("button", { name: "Create worker" }).click();
  assert.match(page.url(), /workers\/demo_worker/);
  assert.match(await page.locator("#source").inputValue(), /defmodule DemoWorker/);
  await page.locator(".cm-editor").waitFor();
  assert.equal(await page.locator("#source").isVisible(), false);
  assert.match(await page.locator(".cm-content").textContent(), /defmodule DemoWorker/);
  await page.locator(".cm-content").click();
  await page.keyboard.press("ControlOrMeta+End");
  await page.keyboard.type("\n# Edited in CodeMirror");
  assert.match(await page.locator("#source").inputValue(), /# Edited in CodeMirror$/);

  await page.getByRole("button", { name: "Compile & deploy" }).click({ timeout: 90_000 });
  await page.getByText("Live endpoint").waitFor({ timeout: 90_000 });
  assert.equal(await (await fetch(`${origin}/run/demo_worker/hello`)).text(), "Hello from demo_worker!\n");
  assert.equal(await (await fetch(`${origin}/run/demo_worker/hello/joe`)).text(), "Hello, joe!\n");
  await page.goto(origin, { waitUntil: "networkidle" });
  assert.match(await page.locator(".worker-table").textContent(), /demo_worker[\s\S]*Deployed[\s\S]*2/);
  await page.screenshot({ path: join(review, "desktop.png"), fullPage: true });
  await page.getByRole("searchbox", { name: "Search workers" }).fill("not_here");
  await page.getByRole("button", { name: "Search" }).click();
  await page.getByText("No matching workers").waitFor();
  await page.getByRole("link", { name: "Clear filters" }).click();
  await page.getByRole("link", { name: "Open demo_worker" }).click();
  await page.evaluate(() => document.fonts.ready);
  await page.screenshot({ path: join(review, "platform-deployed-desktop.png"), fullPage: true });

  const mobile = await browser.newPage({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  mobile.on("pageerror", (error) => errors.push(error.message));
  await mobile.goto(origin, { waitUntil: "networkidle" });
  await mobile.evaluate(() => document.fonts.ready);
  assert.equal(await mobile.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
  await mobile.screenshot({ path: join(review, "mobile.png"), fullPage: true });
  await mobile.getByRole("link", { name: "demo_worker", exact: true }).click();
  assert.equal(await mobile.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
  await mobile.screenshot({ path: join(review, "platform-deployed-mobile.png"), fullPage: true });

  const source = await page.locator("#source").inputValue();
  await page.locator(".cm-content").click();
  await page.keyboard.press("ControlOrMeta+End");
  await page.keyboard.type("\nTHIS IS INVALID ELIXIR");
  assert.equal(await page.locator("#source").inputValue(), source + "\nTHIS IS INVALID ELIXIR");
  await page.getByRole("button", { name: "Compile & deploy" }).click();
  await page.getByRole("alert").waitFor({ timeout: 30_000 });
  assert.match(await page.getByRole("alert").textContent(), /compiler failed/i);
  assert.equal(await (await fetch(`${origin}/run/demo_worker/hello`)).text(), "Hello from demo_worker!\n");
  const noScript = await browser.newPage({ javaScriptEnabled: false });
  await noScript.goto(`${origin}/workers/demo_worker`);
  assert.equal(await noScript.getByLabel("Elixir source").isVisible(), true);
  assert.match(await noScript.getByLabel("Elixir source").inputValue(), /defmodule DemoWorker/);
  await noScript.close();
  assert.deepEqual(errors, []);
  console.log("Browser create/edit/deploy/invoke, rejected compilation and desktop/mobile layout passed.");
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
