import assert from "node:assert/strict";
import test from "node:test";
import { agentActionUrl, postAgentControl } from "../web/control.js";

test("derives control endpoints beside the configured agent endpoint", () => {
  assert.equal(
    agentActionUrl("/api/agent", "cancel", "http://localhost:5173/work").href,
    "http://localhost:5173/api/agent/cancel",
  );
  assert.equal(
    agentActionUrl(
      "http://127.0.0.1:8080/agent?x=1",
      "follow-up",
      "http://localhost/",
    ).href,
    "http://127.0.0.1:8080/agent/follow-up",
  );
});

test("posts run controls with their semantic payload", async () => {
  const calls = [];
  const fetchImpl = async (url, request) => {
    calls.push({ url: String(url), request });
    return { ok: true, status: 202, text: async () => "" };
  };

  await postAgentControl(
    { endpoint: "/agent", runId: "run-1", text: "hold on" },
    "steer",
    fetchImpl,
    "http://localhost:5173/",
  );

  assert.equal(calls[0].url, "http://localhost:5173/agent/steer");
  assert.equal(calls[0].request.method, "POST");
  assert.deepEqual(JSON.parse(calls[0].request.body), {
    runId: "run-1",
    text: "hold on",
  });
});

test("surfaces failed control requests", async () => {
  const fetchImpl = async () => ({
    ok: false,
    status: 404,
    text: async () => '{"error":"run not found"}',
  });

  await assert.rejects(
    postAgentControl(
      { endpoint: "/agent", runId: "gone" },
      "cancel",
      fetchImpl,
      "http://localhost/",
    ),
    /HTTP 404/,
  );
});
