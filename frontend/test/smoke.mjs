// Smoke test: drives the real Elm app in Chromium against a fake backend
// (thread + artifact endpoints). Run with:
//   node test/smoke.mjs
// Requires the global `playwright` npm package and `npm run build` first.
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import http from "node:http";
import net from "node:net";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const dist = path.join(root, "dist");

const require = createRequire(import.meta.url);
const globalRoot = spawnSync("npm", ["root", "-g"], { encoding: "utf8" }).stdout.trim();
const { chromium } = require(path.join(globalRoot, "playwright"));

const now = Math.floor(Date.now() / 1000);
const yuki = "yuki";

const seed = {
  threads: [
    { id: "task-1", title: "架构文档整理", incarnationId: yuki, created: now - 5000, updated: now - 100, archived: false, kind: "task" },
    { id: "task-2", title: "前端交付视图", incarnationId: yuki, created: now - 4000, updated: now - 50, archived: false, kind: "task" },
    { id: "other-1", title: "别的 Yuki 的任务", incarnationId: "other", created: now - 3000, updated: now - 30, archived: false, kind: "task" },
  ],
  artifacts: { "art-1": "artifact payload line one\nartifact payload line two\n".repeat(40) },
};

const json = (response, status, value) => {
  response.writeHead(status, { "content-type": "application/json; charset=utf-8" });
  response.end(JSON.stringify(value));
};

const startFakeBackend = async () => {
  const server = http.createServer(async (request, response) => {
    const url = request.url ?? "/";
    const pathname = new URL(url, "http://x").pathname;

    if (pathname === "/threads") {
      json(response, 200, seed.threads);
      return;
    }
    if (pathname.startsWith("/threads/") && pathname.endsWith("/transcript")) {
      json(response, 200, { messages: [] });
      return;
    }
    if (pathname.startsWith("/artifacts/")) {
      const id = pathname.split("/").pop();
      const content = seed.artifacts[id];
      if (content === undefined) {
        json(response, 404, { error: "artifact not found" });
        return;
      }
      response.writeHead(200, { "content-type": "text/plain; charset=utf-8" });
      response.end(content);
      return;
    }
    json(response, 404, { error: "not found" });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return { server, port: server.address().port };
};

const freePort = () =>
  new Promise((resolve) => {
    const probe = net.createServer();
    probe.listen(0, "127.0.0.1", () => {
      const { port } = probe.address();
      probe.close(() => resolve(port));
    });
  });

const waitFor = async (probe, label, timeoutMs = 10000) => {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await probe()) return;
    await new Promise((resolve) => setTimeout(resolve, 60));
  }
  throw new Error(`timeout waiting for ${label}`);
};

const main = async () => {
  const backend = await startFakeBackend();
  const frontendPort = await freePort();
  const devServer = spawn(
    process.execPath,
    [path.join(root, "scripts", "dev-server.mjs")],
    {
      cwd: root,
      env: {
        ...process.env,
        YUKI_FRONTEND_PORT: String(frontendPort),
        YUKI_BACKEND_URL: `http://127.0.0.1:${backend.port}`,
      },
      stdio: "ignore",
    },
  );

  const base = `http://127.0.0.1:${frontendPort}`;
  try {
    await waitFor(
      async () => {
        try {
          return (await fetch(base)).ok;
        } catch {
          return false;
        }
      },
      "frontend dev server",
    );

    const browser = await chromium.launch({ headless: true });
    const page = await browser.newPage();
    const pageErrors = [];
    page.on("pageerror", (error) => pageErrors.push(error.message));

    await page.goto(`${base}/threads`);
    await page.waitForSelector(".session-row");
    const titles = await page
      .locator(".session-row-title")
      .evaluateAll((rows) => rows.map((row) => row.textContent));
    assert.deepEqual(
      titles,
      ["架构文档整理", "前端交付视图", "别的 Yuki 的任务"],
      "session rows list every task thread",
    );
    await page.locator(".session-row").first().click();
    await page.waitForURL(`**/threads/task-1`);
    await page.waitForSelector(".chat-panel");

    assert.deepEqual(pageErrors, [], "no page errors");
    console.log("smoke ok");
    await browser.close();
  } finally {
    devServer.kill();
    backend.server.close();
  }
};

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
