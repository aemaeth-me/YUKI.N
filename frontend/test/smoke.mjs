// Workbench smoke test: drives the real Elm app in Chromium against a fake
// backend (activity stream + ledger endpoints). Run with:
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
  deliveries: [
    { id: "del-answer", runId: "run-hist", threadId: "task-1", incarnationId: yuki, runKind: "home", kind: "answer", title: "关于架构的最终答复", ref: "msg-final", bytes: null, at: now - 300 },
    { id: "del-file", runId: "run-active", threadId: "task-1", incarnationId: yuki, runKind: "home", kind: "file_write", title: "frontend/src/Main.elm", ref: "frontend/src/Main.elm", bytes: 2048, at: now - 200 },
    { id: "del-art", runId: "run-active", threadId: "task-1", incarnationId: yuki, runKind: "home", kind: "artifact", title: "write_file", ref: "art-1", bytes: 12345, at: now - 100 },
    ...Array.from({ length: 55 }, (_, i) => ({
      id: `del-old-${i}`, runId: "run-hist", threadId: "task-1", incarnationId: yuki, runKind: "home",
      kind: "file_write", title: `legacy/file-${i}.txt`, ref: `legacy/file-${i}.txt`, bytes: 120 + i, at: now - 400 - i,
    })),
  ],
  changes: [
    { id: "chg-tool", runId: "run-active", threadId: "task-1", incarnationId: yuki, path: "frontend/src/Yuki/Changes/View.elm", op: "modified", origin: { kind: "tool", toolName: "write_file", callId: "call-1" }, diff: "--- a/frontend/src/Yuki/Changes/View.elm\n+++ b/frontend/src/Yuki/Changes/View.elm\n@@ -1,4 +1,5 @@\n import Html exposing (..)\n+import Html.Attributes exposing (class)\n-import Html.Events\n import Html.Events exposing (onClick)\n\\ No newline at end of file\n", stat: null, at: now - 210 },
    { id: "chg-git", runId: "run-hist", threadId: "task-1", incarnationId: yuki, path: "docs/agent-workbench/04-前端架构.md", op: "created", origin: { kind: "git" }, diff: null, stat: "1 file changed, 12 insertions(+)", at: now - 150 },
  ],
  threads: [
    { id: "task-1", title: "架构文档整理", incarnationId: yuki, created: now - 5000, updated: now - 100, archived: false, kind: "task" },
    { id: "task-2", title: "前端交付视图", incarnationId: yuki, created: now - 4000, updated: now - 50, archived: false, kind: "task" },
    { id: "other-1", title: "别的 Yuki 的任务", incarnationId: "other", created: now - 3000, updated: now - 30, archived: false, kind: "task" },
  ],
  artifacts: { "art-1": "artifact payload line one\nartifact payload line two\n".repeat(40) },
  summaries: {
    "run-hist": {
      runId: "run-hist", threadId: "task-1", entryCount: 120, turns: 12, toolCalls: 3,
      agentEvents: 60, apiRequests: 15, usage: { prompt: 4000, completion: 1500, cacheHit: 0 },
      memoryCalls: 2, status: "succeeded", firstSeq: 1, lastSeq: 120, firstTime: now - 600, lastTime: now - 240,
    },
  },
  runs: {
    "run-active": {
      runId: "run-active", threadId: "task-1", incarnationId: yuki, parentRunId: null, kind: "home",
      phase: "running", objective: "活跃任务示例", startedAt: now - 500, lastEventAt: now - 10,
      turn: 3, maxTurns: 8, model: "claude-sonnet-4", usage: { promptTokens: 1000, completionTokens: 500 },
      context: null, activeTools: [], workers: 1, lastActivity: "思考中",
    },
    "run-worker-1": {
      runId: "run-worker-1", threadId: "task-1", incarnationId: yuki, parentRunId: "run-active", kind: "worker",
      phase: "awaiting-tool", objective: "Worker 子任务", startedAt: now - 400, lastEventAt: now - 20,
      turn: 2, maxTurns: 5, model: "claude-haiku-4", usage: { promptTokens: 300, completionTokens: 100 },
      context: null, activeTools: [], workers: 0, lastActivity: "等待工具",
    },
  },
};

const counters = { deliveries: 0, changes: 0 };

const query = (url, name) => new URL(url, "http://x").searchParams.get(name);

const pageOf = (items, url, filter, sortKey) => {
  const limit = Math.min(200, Number(query(url, "limit") ?? 50));
  const before = query(url, "before");
  const filtered = items
    .filter((item) => item.incarnationId === filter.incarnation)
    .filter((item) => !filter.threadId || item.threadId === filter.threadId)
    .filter((item) => !filter.runId || item.runId === filter.runId)
    .filter((item) => before === null || item[sortKey] < Number(before))
    .sort((a, b) => b[sortKey] - a[sortKey]);
  return {
    body: { items: filtered.slice(0, limit), hasMore: filtered.length > limit },
    count: Math.min(limit, filtered.length),
  };
};

const json = (response, status, value) => {
  response.writeHead(status, { "content-type": "application/json; charset=utf-8" });
  response.end(JSON.stringify(value));
};

const startFakeBackend = async () => {
  const streamClients = [];
  const server = http.createServer((request, response) => {
    const url = request.url ?? "/";
    const pathname = new URL(url, "http://x").pathname;

    if (pathname === "/activity/stream") {
      response.writeHead(200, {
        "content-type": "text/event-stream",
        "cache-control": "no-store",
        connection: "keep-alive",
      });
      response.write(
        `event: snapshot\ndata: ${JSON.stringify({ incarnations: [{ id: yuki, name: "Yuki", state: "active", activeRuns: 1, waitingDrafts: 0, lastDeliveryAt: now - 100 }], runs: Object.values(seed.runs) })}\n\n`,
      );
      streamClients.push(response);
      request.on("close", () => streamClients.splice(streamClients.indexOf(response), 1));
      return;
    }

    if (pathname === "/__smoke/emit-delivery") {
      const record = {
        id: "del-new", runId: "run-hist", threadId: "task-1", incarnationId: yuki, runKind: "home",
        kind: "answer", title: "tick 后的新交付", ref: "msg-new", bytes: null, at: now - 10,
      };
      seed.deliveries.push(record);
      for (const client of streamClients) {
        client.write(`event: delivery\ndata: ${JSON.stringify(record)}\n\n`);
      }
      json(response, 200, { ok: true });
      return;
    }

    const match = (pattern) => {
      const parts = pattern.split("/").filter(Boolean);
      const actual = pathname.split("/").filter(Boolean);
      if (parts.length !== actual.length) return null;
      const captured = {};
      for (let i = 0; i < parts.length; i++) {
        if (parts[i].startsWith(":")) captured[parts[i].slice(1)] = actual[i];
        else if (parts[i] !== actual[i]) return null;
      }
      return captured;
    };

    let captured;
    if ((captured = match("/incarnations/:id/deliveries"))) {
      counters.deliveries += 1;
      const { body } = pageOf(seed.deliveries, url, { incarnation: captured.id, threadId: query(url, "threadId") }, "at");
      json(response, 200, body);
      return;
    }
    if ((captured = match("/incarnations/:id/fs-changes"))) {
      counters.changes += 1;
      const { body } = pageOf(seed.changes, url, { incarnation: captured.id, threadId: query(url, "threadId"), runId: query(url, "runId") }, "at");
      json(response, 200, body);
      return;
    }
    if (pathname === "/threads") {
      json(response, 200, seed.threads);
      return;
    }
    if ((captured = match("/artifacts/:id"))) {
      const content = seed.artifacts[captured.id];
      if (content === undefined) {
        json(response, 404, { error: "artifact not found" });
        return;
      }
      response.writeHead(200, { "content-type": "text/plain; charset=utf-8" });
      response.end(content);
      return;
    }
    if ((captured = match("/journal/runs/:id/summary"))) {
      const summary = seed.summaries[captured.id];
      if (summary === undefined) {
        json(response, 404, { error: "run not found" });
        return;
      }
      json(response, 200, summary);
      return;
    }
    json(response, 404, { error: "not found" });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return { server, port: server.address().port, streamClients };
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

const visibleText = async (page, selector) => {
  const count = await page.locator(selector).count();
  if (count === 0) return "";
  return (await page.locator(selector).allTextContents()).join(" ");
};

const dumpPage = async (page) => {
  console.log("BODY>>>", (await page.evaluate(() => document.body.innerText)).slice(0, 1200));
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

    await page.goto(`${base}/yuki/${yuki}/deliveries`);
    try {
      await page.waitForSelector(".delivery-card", { timeout: 15000 });
    } catch (error) {
      await dumpPage(page);
      throw error;
    }
    assert.equal(await page.locator(".delivery-card").count(), 50, "first page is capped at 50");
    assert.match(await visibleText(page, ".delivery-card"), /关于架构的最终答复/);
    assert.match(await visibleText(page, ".delivery-card"), /frontend\/src\/Main\.elm/);

    await page.locator(".delivery-card", { hasText: "write_file" }).locator(".delivery-row").click();
    await page.waitForSelector(".artifact-content");
    assert.match(await visibleText(page, ".artifact-content"), /artifact payload line one/);

    const fileRow = page.locator(".delivery-card", { hasText: "frontend/src/Main.elm" });
    await fileRow.locator(".delivery-row").click();
    assert.equal(await fileRow.locator(".delivery-path").textContent(), "frontend/src/Main.elm");
    assert.equal(await fileRow.locator(".delivery-copy").textContent(), "复制路径");

    await page.locator(".chip", { hasText: "答案" }).click();
    await waitFor(async () => (await page.locator(".delivery-card").count()) === 1, "answer filter keeps only answers");
    await page.locator(".chip", { hasText: "全部" }).click();
    await waitFor(async () => (await page.locator(".delivery-card").count()) === 50, "all filter restores the list");

    await page.locator(".wb-more", { hasText: "加载更多" }).click();
    await waitFor(
      async () => (await page.locator(".delivery-card").count()) === 58,
      "paged deliveries",
    );

    const beforeEmit = counters.deliveries;
    await fetch(`http://127.0.0.1:${backend.port}/__smoke/emit-delivery`);
    await waitFor(async () => counters.deliveries > beforeEmit, "tick refetch of deliveries");
    await page.waitForSelector(".delivery-card", { hasText: "tick 后的新交付" });

    await page.goto(`${base}/yuki/${yuki}/changes`);
    await page.waitForSelector(".change-card");
    assert.equal(await page.locator(".change-card").count(), 2);
    assert.equal(await page.locator(".wb-select option").count(), 3, "thread filter lists tasks of this yuki");

    const toolRow = page.locator(".change-card", { hasText: "Yuki/Changes/View.elm" });
    await toolRow.locator(".change-row").click();
    await toolRow.locator(".diff").waitFor();
    assert.equal(await toolRow.locator(".diff-add").count(), 1, "diff addition line rendered");
    assert.equal(await toolRow.locator(".diff-remove").count(), 1, "diff removal line rendered");
    assert.ok((await toolRow.locator(".diff-context").count()) > 0, "diff context line rendered");

    const gitRow = page.locator(".change-card", { hasText: "04-前端架构.md" });
    await gitRow.locator(".change-row").click();
    await gitRow.locator(".change-git-note").waitFor();
    assert.match(await visibleText(page, ".change-git-note"), /1 file changed, 12 insertions\(\+\)/);
    assert.match(await visibleText(page, ".change-git-note"), /由 git 补记，内容以工作区为准/);

    await page.goto(`${base}/yuki/${yuki}/run/run-active`);
    await page.waitForSelector(".run-status-card");
    assert.match(await visibleText(page, ".run-status-card"), /活跃任务示例/);
    await page.waitForSelector(".worker-row");
    assert.equal(
      await page.locator(".worker-link").first().getAttribute("href"),
      "/yuki/yuki/run/run-worker-1",
    );
    await waitFor(
      async () => (await page.locator(".run-monitor .delivery-row").count()) === 2,
      "active run deliveries",
    );
    assert.match(await visibleText(page, ".run-monitor .delivery-list"), /frontend\/src\/Main\.elm/);
    assert.doesNotMatch(await visibleText(page, ".run-monitor .delivery-list"), /关于架构的最终答复/, "deliveries are filtered by runId");
    await waitFor(
      async () => (await page.locator(".run-monitor .change-row").count()) === 1,
      "active run changes",
    );

    await page.goto(`${base}/yuki/${yuki}/run/run-hist`);
    await page.waitForSelector(".run-summary");
    assert.match(await visibleText(page, ".run-monitor"), /已结束/);
    assert.match(await visibleText(page, ".run-summary"), /succeeded/);
    assert.match(await visibleText(page, ".run-summary"), /12/);
    assert.match(await visibleText(page, ".run-summary"), /6m 0s/, "duration rendered from first/last time");
    await waitFor(
      async () => (await page.locator(".run-monitor .delivery-row").count()) >= 2,
      "historical run deliveries",
    );
    await waitFor(
      async () => (await page.locator(".run-monitor .change-row").count()) === 1,
      "historical run changes",
    );
    assert.match(await visibleText(page, ".run-monitor .change-list"), /04-前端架构\.md/);

    await page.goto(`${base}/yuki/${yuki}/tasks`);
    await page.waitForSelector(".wb-task-row-link");
    const taskHrefs = await page
      .locator(".wb-task-row-link")
      .evaluateAll((rows) => rows.map((row) => row.getAttribute("href")).sort());
    assert.deepEqual(
      taskHrefs,
      ["/yuki/yuki/chat/task-1", "/yuki/yuki/chat/task-2"],
      "task rows link to their chats",
    );

    assert.deepEqual(pageErrors, [], "no page errors");
    console.log(
      `smoke ok: deliveries=${counters.deliveries} changes=${counters.changes} streamClients=${backend.streamClients.length}`,
    );
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
