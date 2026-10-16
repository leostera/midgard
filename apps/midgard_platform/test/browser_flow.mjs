import assert from "node:assert/strict";
import { spawn } from "node:child_process";
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
  await page.evaluate(() => document.fonts.ready);
  await page.screenshot({ path: join(review, "platform-empty-desktop.png"), fullPage: true });
  await page.getByRole("link", { name: "Create worker" }).first().click();
  await page.getByLabel("Worker name").fill("demo_worker");
  await page.getByRole("button", { name: "Create worker" }).click();
  assert.match(page.url(), /workers\/demo_worker/);
  assert.match(await page.getByLabel("Elixir source").inputValue(), /defmodule DemoWorker/);

  await page.getByRole("button", { name: "Compile & deploy" }).click({ timeout: 90_000 });
  await page.getByText("Live endpoint").waitFor({ timeout: 90_000 });
  assert.equal(await (await fetch(`${origin}/run/demo_worker/hello`)).text(), "Hello from demo_worker!\n");
  await page.evaluate(() => document.fonts.ready);
  await page.screenshot({ path: join(review, "platform-deployed-desktop.png"), fullPage: true });

  const mobile = await browser.newPage({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  mobile.on("pageerror", (error) => errors.push(error.message));
  await mobile.goto(`${origin}/workers/demo_worker`, { waitUntil: "networkidle" });
  await mobile.evaluate(() => document.fonts.ready);
  assert.equal(await mobile.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
  await mobile.screenshot({ path: join(review, "platform-deployed-mobile.png"), fullPage: true });

  const source = await page.getByLabel("Elixir source").inputValue();
  await page.getByLabel("Elixir source").fill(source + "\nTHIS IS INVALID ELIXIR");
  await page.getByRole("button", { name: "Compile & deploy" }).click();
  await page.getByRole("alert").waitFor({ timeout: 30_000 });
  assert.match(await page.getByRole("alert").textContent(), /compiler failed/i);
  assert.equal(await (await fetch(`${origin}/run/demo_worker/hello`)).text(), "Hello from demo_worker!\n");
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
