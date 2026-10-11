import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync, mkdirSync } from "node:fs";
import { createServer } from "node:net";
import { setTimeout as pause } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright-core";

const project = fileURLToPath(new URL("..", import.meta.url));
const chrome = process.env.CHROME_PATH;
if (!chrome || !existsSync(chrome)) {
  throw new Error("Set CHROME_PATH to a Chrome/Chromium executable before running this optional browser check.");
}

const port = await freePort();
const origin = `http://127.0.0.1:${port}`;
const server = spawn("mix", ["run", "--no-halt"], {
  cwd: project,
  env: { ...process.env, TODO_PORT: String(port), MIX_ENV: "dev" },
  detached: process.platform !== "win32",
  stdio: ["ignore", "pipe", "pipe"]
});
let serverLog = "";
for (const stream of [server.stdout, server.stderr]) {
  stream.on("data", (data) => { serverLog = (serverLog + data.toString()).slice(-16_000); });
}

let browser;
try {
  await waitForServer(server, origin);
  browser = await chromium.launch({ executablePath: chrome, headless: true });
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  page.on("console", (message) => { if (message.type() === "error") errors.push(message.text()); });
  await page.goto(origin, { waitUntil: "networkidle" });
  await page.evaluate(() => document.fonts.ready);
  assert.equal(await page.locator("#empty-state").isVisible(), true);
  const input = page.getByLabel("Add a task");

  for (const title of ["Review the build", "Write the walkthrough"]) {
    await input.fill(title);
    await page.getByRole("button", { name: "Add task" }).click();
    await page.locator(".task-row", { hasText: title }).waitFor();
  }

  const review = page.locator(".task-row", { hasText: "Review the build" });
  await review.locator('[data-action="toggle"]').click();
  await page.waitForFunction(() => document.querySelector('.task-row [data-action="toggle"]')?.getAttribute("aria-pressed") === "true");
  assert.match(await page.locator("#progress-count").textContent(), /1 of 2 complete/);

  const writing = page.locator(".task-row", { hasText: "Write the walkthrough" });
  await writing.locator('[data-action="edit"]').click();
  await writing.locator(".edit-input").fill("Write the guide");
  await writing.locator('button[type="submit"]').click();
  const updated = page.locator(".task-row", { hasText: "Write the guide" });
  await updated.waitFor();
  await updated.locator('[data-action="delete"]').click();
  assert.equal(await updated.locator('[data-action="delete"]').textContent(), "Confirm remove");
  assert.equal(await updated.isVisible(), true);
  await updated.locator('[data-action="delete"]').click();
  await updated.waitFor({ state: "detached" });

  await input.fill("ø".repeat(81)); // 162 UTF-8 bytes; maxlength alone does not catch this.
  await page.getByRole("button", { name: "Add task" }).click();
  assert.match(await page.locator("#feedback").textContent(), /1–160 bytes/);
  assert.equal(await page.locator(".task-row").count(), 1);

  await input.fill("Check the browser");
  await page.getByRole("button", { name: "Add task" }).click();
  await page.locator(".task-row", { hasText: "Check the browser" }).waitFor();
  await page.evaluate(() => document.fonts.ready);
  await pause(300); // Capture the final, not the in-flight, completion stamp.
  await capture(page, "desktop.png");

  const mobile = await browser.newPage({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  mobile.on("pageerror", (error) => errors.push(error.message));
  await mobile.goto(origin, { waitUntil: "networkidle" });
  await mobile.evaluate(() => document.fonts.ready);
  assert.equal(await mobile.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
  assert.equal(await mobile.getByRole("button", { name: "Add task" }).isVisible(), true);
  assert.equal(await mobile.locator(".task-row").count(), 2);
  await capture(mobile, "mobile.png");
  assert.deepEqual(errors, []);
  console.log("Browser CRUD, rejection, empty state and desktop/mobile layout passed.");
} finally {
  if (browser) await browser.close();
  if (server.exitCode === null) {
    if (process.platform === "win32") server.kill("SIGTERM");
    else process.kill(-server.pid, "SIGTERM");
  }
}

async function freePort() {
  const listener = createServer();
  await new Promise((resolve, reject) => listener.listen(0, "127.0.0.1", (error) => error ? reject(error) : resolve()));
  const { port } = listener.address();
  await new Promise((resolve) => listener.close(resolve));
  return port;
}

async function waitForServer(process, url) {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (process.exitCode !== null) throw new Error(`Local server exited early:\n${serverLog}`);
    try {
      const response = await fetch(`${url}/api/todos`);
      if (response.ok) return;
    } catch { /* Still starting. */ }
    await pause(150);
  }
  throw new Error(`Timed out starting local server:\n${serverLog}`);
}

async function capture(page, filename) {
  const directory = process.env.MIDGARD_SCREENSHOT_DIR;
  if (!directory) return;
  mkdirSync(directory, { recursive: true });
  await page.screenshot({ path: `${directory}/${filename}`, fullPage: true });
}
